#!/usr/bin/env python3
"""Generate the wave-1 MF2 Stage-2 ablation configs (LOBO + LOBI).

Pre-registered protocol (MF2_FEATURE_DISCOVERY_PLAN §3, senior-approved):
- Unit of ablation = a BLOCK (never individual features).
- Each feature-set gets its OWN 32-sample HPO refresh (HPO's only role is a fair
  tuned score per set; it does NOT search over features).
- Fold set = pre-registered v2 set: confirmatory {2024-07,2024-11,2025-03} + the
  recent OOT promotion block 2025-07..2026-04. OOT block is the SINGLE promotion
  metric; confirmatory months are robustness only (read post-hoc from OOF).
- 500k train rows (the c-4 feasible fidelity ceiling), panel_v2.

Sets (12): base15 · LOBI base+each block · all-in · LOBO all-minus-each block.
Deltas (vs RW-drift, OOT block, >=8/10 month consistency, band) are read later by
ml/mf2/train_eval.py from the per-set OOF — NOT here.
"""
from __future__ import annotations
import pathlib
import yaml

OUT = pathlib.Path(__file__).resolve().parents[1] / "configs" / "ablation"

# The 15 incumbents (must match tune_mf2.FEATURES exactly).
BASE = [
    "f_lis_log", "f_lis_dlog_h", "f_lis_dlog_28", "f_lis_dlog_90",
    "f_lis_slope_90", "f_lis_logstd_90", "f_lis_obs_90",
    "f_lis_age_days", "f_fol_log", "f_fol_dlog_28", "f_fol_lis_ratio_log",
    "f_pop", "f_cm_score", "f_cm_rank_neglog", "f_month",
]
# Wave-1 blocks — real panel_v2 columns (3 per block: level, momentum, presence).
BLOCKS = {
    "ttp": ["f_ttp_log", "f_ttp_dlog_28", "f_ttp_present"],  # tiktok_sound_posts
    "ytv": ["f_ytv_log", "f_ytv_dlog_28", "f_ytv_present"],  # youtube_views
    "yts": ["f_yts_log", "f_yts_dlog_28", "f_yts_present"],  # youtube_subscribers
    "wik": ["f_wik_log", "f_wik_dlog_28", "f_wik_present"],  # wikipedia_views
    "gen": ["f_gen_log", "f_gen_dlog_28", "f_gen_present"],  # genius_views
}
ALL_BLOCK_COLS = [c for cols in BLOCKS.values() for c in cols]

V2_FOLDS = [
    "2024-07", "2024-11", "2025-03",                          # confirmatory
    "2025-07", "2025-08", "2025-09", "2025-10", "2025-11",    # OOT promotion block
    "2025-12", "2026-01", "2026-02", "2026-03", "2026-04",
]


def cfg(name: str, features: list[str]) -> dict:
    return {
        "cpus_per_trial": 4,
        "max_concurrent_trials": 10,
        "metric": "mean_pinball",
        "mode": "min",
        "num_samples": 32,
        "asha_grace_period": 2,
        "asha_reduction_factor": 3,
        "ray_results_dir": "artifacts/ray_results",
        "live_events_path": "artifacts/live/trial_events.jsonl",
        "panel_path": "/data/tune/panel_v2.parquet",
        "eval_months": V2_FOLDS,
        "fold_shuffle_seed": 20260723,
        "min_train_months": 12,
        "train_sample": 500000,
        "name": name,
        "save_predictions_dir": f"/data/tune/oof/{name}",
        "features": features,
    }


def build() -> dict[str, dict]:
    sets: dict[str, list[str]] = {"mf2_abl_base15": list(BASE)}
    for blk, cols in BLOCKS.items():                       # LOBI
        sets[f"mf2_abl_lobi_{blk}"] = BASE + cols
    sets["mf2_abl_allin"] = BASE + ALL_BLOCK_COLS          # all-in anchor
    for blk, cols in BLOCKS.items():                       # LOBO
        drop = set(cols)
        sets[f"mf2_abl_lobo_{blk}"] = BASE + [c for c in ALL_BLOCK_COLS if c not in drop]
    return sets


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    sets = build()
    for name, feats in sets.items():
        path = OUT / f"{name}.yaml"
        with open(path, "w") as fh:
            yaml.safe_dump(cfg(name, feats), fh, sort_keys=False, default_flow_style=False)
        print(f"wrote {path.name:28s} ({len(feats)} features)")
    print(f"\n{len(sets)} configs -> {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
