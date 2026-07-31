"""Distributed MF2 hyperparameter search on the Ray fleet.

MF2 = Spotify Artist Audience Stock. Each Ray Tune trial trains an XGBoost
multi-quantile model (7-grid p05..p95) on the leakage-safe MF2 panel built in the
demo repo, evaluated on a date-embargoed grouped temporal walk-forward over
era-stratified resolution-month folds (reported in a fixed shuffled order shared
by all trials), and reports the running-mean pinball loss (the metric that
captures MF2's real deliverable: calibrated audience-stock intervals). ASHA
prunes weak configs early.

The panel parquet is synced to every worker at PANEL_PATH (default /data/tune/…)
by `make sync-data`. This trainable never touches the read-only bronze; it only
reads the compact supervised panel.

Governance: preliminary experiment-ladder evidence. Nothing here promotes a model
or flips a model_eligible gate. cm_artist_id is the working key; listeners is a
label candidate pending the reconciliation study.
"""

from __future__ import annotations

import argparse
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import ray
import yaml
from ray import tune
from ray.tune import RunConfig
from ray.tune.schedulers import ASHAScheduler

from .live_callback import LiveJsonlCallback

FEATURES = [
    "f_lis_log", "f_lis_dlog_h", "f_lis_dlog_28", "f_lis_dlog_90",
    "f_lis_slope_90", "f_lis_logstd_90", "f_lis_obs_90",
    "f_lis_age_days", "f_fol_log", "f_fol_dlog_28", "f_fol_lis_ratio_log",
    "f_pop", "f_cm_score", "f_cm_rank_neglog", "f_month",
]
TARGET = "label_change_log"
# Dense grid from the start: the close-race gate needs a per-artist predictive CDF,
# and discovering missing quantiles AFTER the HPO means re-running the whole search.
# Multi-quantile XGBoost trains ONE model with K shared-tree outputs, so 3->7 costs
# far less than 7/3x. Monotonicity enforced post-hoc via np.sort (wiki-sanctioned).
QUANTILES = [0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95]
COLS = FEATURES + [TARGET, "fold_month", "horizon_days", "cutoff", "resolve_date",
                   "cm_artist_id"]

DEFAULT_PANEL = "/data/tune/panel_h28.parquet"

# Spaces (S3) credentials are read from the environment and propagated to workers
# via Ray runtime_env (see main) — NEVER baked into cloud-init or Terraform args.
SPACES_ENV_KEYS = ("DO_SPACES_KEY", "DO_SPACES_SECRET", "DO_SPACES_ENDPOINT")


def load_config(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _load_panel(uri: str, columns: list[str],
                months: list[str] | None = None) -> pd.DataFrame:
    """Load the supervised panel from a local path OR a DO Spaces (S3) URI.

    Local path (default): plain `read_parquet` — the rsync data plane. Fine for the
    ~500MB MF2 panel that fits every droplet's 50GB disk and 8GB RAM many times over.

    `s3://bucket/prefix` (Spaces): read a HIVE-partitioned parquet dataset straight
    from object storage with **projection** (only `columns`) and optional **partition
    pushdown** (`fold_month in months`), so a droplet pulls only the subpart it needs
    and RAM stays bounded regardless of total dataset size — the path for the big
    MF1 / stacked-horizon panels that don't fit a c-4's 8GB. Credentials come from the
    environment (SPACES_ENV_KEYS), propagated to workers by Ray runtime_env.

    Both return the same in-memory DataFrame contract, so the trainable is agnostic.
    """
    if uri.startswith("s3://"):
        import pyarrow.dataset as ds
        from pyarrow.fs import S3FileSystem

        fs = S3FileSystem(
            access_key=os.environ["DO_SPACES_KEY"],
            secret_key=os.environ["DO_SPACES_SECRET"],
            endpoint_override=os.environ["DO_SPACES_ENDPOINT"],
        )
        dataset = ds.dataset(uri[len("s3://"):], filesystem=fs,
                             format="parquet", partitioning="hive")
        filt = ds.field("fold_month").isin(months) if months else None
        return dataset.to_table(columns=columns, filter=filt).to_pandas()
    return pd.read_parquet(uri, columns=columns)


def _pinball(y: np.ndarray, q_pred: np.ndarray, alpha: float) -> float:
    d = y - q_pred
    return float(np.mean(np.maximum(alpha * d, (alpha - 1) * d)))


def _select_eval_months(months: list[str], config: dict[str, Any]) -> list[str]:
    """Choose the eval folds and their REPORTING order.

    `eval_months` (explicit list, e.g. era-stratified) overrides the default
    trailing `n_eval` window. `fold_shuffle_seed` then applies a FIXED permutation
    shared by every trial (same seed -> same order): folds reported chronologically
    would make ASHA's first rung prune on the OLDEST regime, selecting for
    backward-generalizing configs; a shared shuffle makes rung 1 an unbiased draw
    from the era mix while keeping trials comparable at every rung.
    """
    explicit = config.get("eval_months")
    if explicit:
        missing = [m for m in explicit if m not in months]
        if missing:
            raise ValueError(f"eval_months not in panel: {missing}")
        sel = list(explicit)
    else:
        sel = months[-int(config.get("n_eval", 4)):]
    seed = config.get("fold_shuffle_seed")
    if seed is not None:
        order = np.random.default_rng(int(seed)).permutation(len(sel))
        sel = [sel[i] for i in order]
    return sel


def train_mf2(config: dict[str, Any]) -> None:
    import xgboost as xgb

    # fixed_trials mode: the grid point is a complete param dict (config + seed +
    # optional per-trial train_sample override) nested under "_fixed"; flatten it
    # over the shared base so the rest of the trainable is mode-agnostic.
    if config.get("_fixed"):
        config = {**config, **config["_fixed"]}

    panel_uri = config.get("panel_uri") or config.get("panel_path", DEFAULT_PANEL)
    train_sample = int(config.get("train_sample", 0))  # 0 = all rows
    seed = int(config.get("seed", 17))
    min_train_months = int(config.get("min_train_months", 12))
    save_preds_dir = config.get("save_predictions_dir") or ""

    # Ablation-aware feature set: a trial may override FEATURES with an explicit
    # `features` list (LOBO/LOBI); default = the 15 incumbents, i.e. identical to the
    # pre-ablation behavior. `load_columns` (the union across all trials, computed in
    # build_search_space) drives the parquet projection so one load serves every
    # trial's feature set.
    feats = list(config.get("features") or FEATURES)
    load_cols = config.get("load_columns") or COLS
    df = _load_panel(panel_uri, load_cols, config.get("panel_months"))
    missing = [f for f in feats if f not in df.columns]
    if missing:
        raise ValueError(
            f"panel {panel_uri} is missing {len(missing)} feature column(s) this "
            f"trial's feature set requires: {missing[:8]}"
            + ("…" if len(missing) > 8 else "")
        )
    # Downcast feature/target matrix to float32: halves the per-trial panel copy
    # (~800MB -> ~400MB) so two trials fit a c-4's 8GB with Ray overhead to spare.
    for c in feats + [TARGET]:
        if df[c].dtype == "float64":
            df[c] = df[c].astype("float32")
    months = sorted(df["fold_month"].unique().tolist())
    eval_months = _select_eval_months(months, config)

    params = {
        "objective": "reg:quantileerror",
        "quantile_alpha": QUANTILES,
        "tree_method": "hist",
        "nthread": int(config.get("nthread", 2)),
        "max_depth": int(config["max_depth"]),
        "eta": float(config["eta"]),
        "subsample": float(config["subsample"]),
        "colsample_bytree": float(config["colsample_bytree"]),
        "min_child_weight": float(config["min_child_weight"]),
        "reg_lambda": float(config["reg_lambda"]),
        "reg_alpha": float(config["reg_alpha"]),
    }
    rounds = int(config["num_boost_round"])

    pinballs: list[float] = []
    covers: list[float] = []
    rng = np.random.default_rng(seed)
    for m in eval_months:
        te = df[df["fold_month"] == m]
        if te.empty:
            continue
        # Deployment-faithful embargo: a training row is usable only if its label
        # has already RESOLVED by the moment we forecast this fold (its cutoff).
        # A month-count embargo is wrong once cutoff = resolve - h slides with h.
        test_cutoff = te["cutoff"].min()
        tr = df[df["resolve_date"] <= test_cutoff]
        # Minimum-history floor in MONTHS, not rows: what makes an early fold
        # pathological is regime coverage, and 5000 rows can be one thin month.
        # Data-dependent, so every trial skips the same folds -> rungs comparable.
        if len(tr) < 5000 or tr["fold_month"].nunique() < min_train_months:
            continue
        if train_sample and len(tr) > train_sample:
            idx = rng.choice(len(tr), size=train_sample, replace=False)
            tr = tr.iloc[idx]
        dtr = xgb.QuantileDMatrix(tr[feats], label=tr[TARGET].to_numpy())
        dte = xgb.QuantileDMatrix(te[feats], ref=dtr)
        model = xgb.train(params, dtr, num_boost_round=rounds)
        qp = np.sort(model.predict(dte), axis=1)
        y = te[TARGET].to_numpy()
        pb = float(np.mean([_pinball(y, qp[:, i], a) for i, a in enumerate(QUANTILES)]))
        # Coverage of the outer band = between the lowest and highest quantile
        # (p05..p95 here), by position so it stays correct as QUANTILES grows.
        cov = float(np.mean((y >= qp[:, 0]) & (y <= qp[:, -1])))
        pinballs.append(pb)
        covers.append(cov)
        if save_preds_dir:
            # OOF quantile predictions for finalist runs (off during HPO): feeds
            # the close-race simulator / conformal / ensemble lanes retrain-free.
            # Written on the worker; pull via artifacts sync after the run.
            pdir = Path(save_preds_dir) / tune.get_context().get_trial_id()
            pdir.mkdir(parents=True, exist_ok=True)
            out = te[["cm_artist_id", "cutoff", "resolve_date", "horizon_days",
                      "fold_month"]].copy()
            out[TARGET] = y
            for i, a in enumerate(QUANTILES):
                out[f"q{int(a*100):02d}"] = qp[:, i]
            out.to_parquet(pdir / f"preds_{m}.parquet", index=False)
        # Report the RUNNING mean after every fold (not once at the end) so
        # ASHAScheduler has intermediate rungs to prune weak configs after fold 1.
        # A single terminal report would make the scheduler a no-op.
        tune.report({
            "mean_pinball": float(np.mean(pinballs)),
            "coverage": float(np.mean(covers)),      # target ~0.90 for p05..p95
            "cover_gap": float(abs(np.mean(covers) - 0.90)),
            "n_folds": len(pinballs),
        })

    if not pinballs:
        tune.report({"mean_pinball": float("inf"), "coverage": 0.0,
                     "cover_gap": 1.0, "n_folds": 0})


def build_search_space(cfg: dict[str, Any]) -> dict[str, Any]:
    base = {
        "panel_path": cfg.get("panel_path", DEFAULT_PANEL),
        "panel_uri": cfg.get("panel_uri"),        # s3://… for Spaces, else local
        "panel_months": cfg.get("panel_months"),  # optional fold_month pushdown
        "n_eval": cfg.get("n_eval", 4),
        "eval_months": cfg.get("eval_months"),
        "fold_shuffle_seed": cfg.get("fold_shuffle_seed"),
        "min_train_months": cfg.get("min_train_months", 12),
        "save_predictions_dir": cfg.get("save_predictions_dir"),
        "train_sample": cfg.get("train_sample", 0),
        "nthread": cfg.get("cpus_per_trial", 2),
    }
    # fixed_trials: enumerated complete configs (seed replicates, fidelity ladder,
    # finalist re-scores). Each entry is one trial, run to ALL folds — no search,
    # no ASHA (see main). Entries may override any base key (seed, train_sample…).
    fixed = cfg.get("fixed_trials")
    # Ablation support: a trial (fixed) or the run (search) may carry its own
    # `features`. The parquet projection must load the UNION of every trial's features
    # plus the non-feature columns so one _load_panel serves all trials. With no
    # override this is exactly COLS -> unchanged behavior for every prior config.
    base["features"] = cfg.get("features")  # top-level default (search mode)
    trial_feature_lists = (
        [t.get("features") for t in fixed] if fixed else [cfg.get("features")]
    )
    seen: set[str] = set()
    feat_union: list[str] = []
    for fl in trial_feature_lists:
        for f in (fl or FEATURES):
            if f not in seen:
                seen.add(f)
                feat_union.append(f)
    non_feature_cols = [c for c in COLS if c not in FEATURES]
    base["load_columns"] = feat_union + [c for c in non_feature_cols if c not in seen]
    if fixed:
        base["_fixed"] = tune.grid_search(list(fixed))
        return base
    base.update({
        "max_depth": tune.choice([4, 6, 8, 10]),
        "eta": tune.loguniform(0.01, 0.2),
        "subsample": tune.uniform(0.6, 1.0),
        "colsample_bytree": tune.uniform(0.6, 1.0),
        "min_child_weight": tune.choice([5, 20, 50, 100]),
        "reg_lambda": tune.loguniform(0.1, 50.0),
        "reg_alpha": tune.loguniform(1e-4, 10.0),
        "num_boost_round": tune.choice([200, 400, 700]),
    })
    return base


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="configs/tune_mf2.yaml")
    args = parser.parse_args()
    cfg = load_config(args.config)

    # When the panel lives in Spaces, propagate the S3 credentials to every worker
    # through Ray's runtime_env env_vars — sourced from the head's environment (.env),
    # never from cloud-init or Terraform. No-op for the local/rsync path.
    runtime_env = None
    if str(cfg.get("panel_uri", "")).startswith("s3://"):
        missing = [k for k in SPACES_ENV_KEYS if not os.environ.get(k)]
        if missing:
            raise SystemExit(f"panel_uri is s3:// but missing env creds: {missing}")
        runtime_env = {"env_vars": {k: os.environ[k] for k in SPACES_ENV_KEYS}}

    if not ray.is_initialized():
        ray.init(address="auto", ignore_reinit_error=True,
                 runtime_env=runtime_env)

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    Path(cfg.get("live_events_path", "artifacts/live/trial_events.jsonl")).parent.mkdir(
        parents=True, exist_ok=True)
    Path(cfg.get("ray_results_dir", "artifacts/ray_results")).mkdir(
        parents=True, exist_ok=True)

    # fixed_trials runs replicates/ladders: every trial must reach ALL folds, so
    # ASHA is off (it would prune seed replicates on fold noise). num_samples=1:
    # grid_search already enumerates one trial per entry.
    fixed_mode = bool(cfg.get("fixed_trials"))
    tuner = tune.Tuner(
        tune.with_resources(train_mf2, {"cpu": int(cfg.get("cpus_per_trial", 2))}),
        param_space=build_search_space(cfg),
        tune_config=tune.TuneConfig(
            metric=cfg.get("metric", "mean_pinball"),
            mode=cfg.get("mode", "min"),
            num_samples=1 if fixed_mode else int(cfg.get("num_samples", 48)),
            max_concurrent_trials=int(cfg.get("max_concurrent_trials", 12)),
            # grace_period=2: no config dies on a single fold. With 6 folds and
            # rf=3 the rungs land at 2 and 6 -- sensible geometry; grace=1 would
            # prune on whichever single fold reports first.
            scheduler=None if fixed_mode else ASHAScheduler(
                grace_period=int(cfg.get("asha_grace_period", 2)),
                reduction_factor=int(cfg.get("asha_reduction_factor", 3))),
        ),
        run_config=RunConfig(
            name=cfg.get("name", "mf2_xgb_quantile_hpo"),
            storage_path=str(Path(cfg.get("ray_results_dir", "artifacts/ray_results")).resolve()),
            callbacks=[LiveJsonlCallback(
                cfg.get("live_events_path", "artifacts/live/trial_events.jsonl"),
                run_id=run_id)],
        ),
    )
    print("RUN_ID", run_id)
    results = tuner.fit()
    best = results.get_best_result(
        metric=cfg.get("metric", "mean_pinball"), mode=cfg.get("mode", "min"))
    print("BEST_RESULT", best.metrics)
    print("BEST_CONFIG", best.config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
