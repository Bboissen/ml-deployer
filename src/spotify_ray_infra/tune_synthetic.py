from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import ray
import yaml
from ray import tune
from ray.tune import RunConfig
from ray.tune.schedulers import ASHAScheduler
from sklearn.datasets import make_regression
from sklearn.metrics import mean_squared_error
from sklearn.model_selection import train_test_split

from .live_callback import LiveJsonlCallback


def load_config(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def train_synthetic(config: dict[str, Any]) -> None:
    import lightgbm as lgb

    n_rows = int(config.get("n_rows", 25000))
    n_features = int(config.get("n_features", 40))
    random_state = int(config.get("random_state", 42))

    X, y = make_regression(
        n_samples=n_rows,
        n_features=n_features,
        n_informative=max(5, n_features // 3),
        noise=0.25,
        random_state=random_state,
    )
    X = X.astype(np.float32)
    y = np.log1p(np.abs(y - y.min()) + 1.0).astype(np.float32)

    X_train, X_valid, y_train, y_valid = train_test_split(X, y, test_size=0.2, random_state=random_state)

    params = {
        "objective": "regression",
        "metric": "rmse",
        "verbosity": -1,
        "num_threads": int(config.get("num_threads", 1)),
        "num_leaves": int(config["num_leaves"]),
        "learning_rate": float(config["learning_rate"]),
        "feature_fraction": float(config["feature_fraction"]),
        "bagging_fraction": float(config["bagging_fraction"]),
        "bagging_freq": 1,
        "max_bin": int(config["max_bin"]),
        "lambda_l1": float(config["lambda_l1"]),
        "lambda_l2": float(config["lambda_l2"]),
    }

    train_set = lgb.Dataset(X_train, label=y_train)
    valid_set = lgb.Dataset(X_valid, label=y_valid)
    evals: dict[str, Any] = {}
    model = lgb.train(
        params,
        train_set,
        valid_sets=[valid_set],
        valid_names=["valid"],
        num_boost_round=int(config.get("num_boost_round", 300)),
        callbacks=[lgb.early_stopping(30), lgb.record_evaluation(evals), lgb.log_evaluation(0)],
    )
    pred = model.predict(X_valid, num_iteration=model.best_iteration)
    rmse = float(np.sqrt(mean_squared_error(y_valid, pred)))

    tune.report(
        {
            "val_rmse": float(rmse),
            "best_iteration": int(model.best_iteration or 0),
            "n_rows": n_rows,
            "n_features": n_features,
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="configs/tune_synthetic.yaml")
    args = parser.parse_args()
    cfg = load_config(args.config)

    if not ray.is_initialized():
        ray.init(address="auto", ignore_reinit_error=True)

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    Path(cfg.get("live_events_path", "artifacts/live/trial_events.jsonl")).parent.mkdir(parents=True, exist_ok=True)
    Path(cfg.get("ray_results_dir", "artifacts/ray_results")).mkdir(parents=True, exist_ok=True)

    search_space = {
        "n_rows": cfg.get("n_rows", 25000),
        "n_features": cfg.get("n_features", 40),
        "random_state": tune.randint(1, 100000),
        "num_threads": cfg.get("cpus_per_trial", 1),
        "num_leaves": tune.choice([15, 31, 63]),
        "learning_rate": tune.loguniform(0.01, 0.15),
        "feature_fraction": tune.uniform(0.6, 1.0),
        "bagging_fraction": tune.uniform(0.6, 1.0),
        "max_bin": tune.choice([63, 127]),
        "lambda_l1": tune.loguniform(1e-4, 10.0),
        "lambda_l2": tune.loguniform(0.1, 50.0),
        "num_boost_round": tune.choice([150, 300, 600]),
    }

    tuner = tune.Tuner(
        tune.with_resources(train_synthetic, {"cpu": int(cfg.get("cpus_per_trial", 1))}),
        param_space=search_space,
        tune_config=tune.TuneConfig(
            metric=cfg.get("metric", "val_rmse"),
            mode=cfg.get("mode", "min"),
            num_samples=int(cfg.get("num_samples", 24)),
            max_concurrent_trials=int(cfg.get("max_concurrent_trials", 8)),
            scheduler=ASHAScheduler(grace_period=1, reduction_factor=3),
        ),
        run_config=RunConfig(
            name=cfg.get("name", "synthetic_lgbm_smoke"),
            storage_path=str(Path(cfg.get("ray_results_dir", "artifacts/ray_results")).resolve()),
            callbacks=[LiveJsonlCallback(cfg.get("live_events_path", "artifacts/live/trial_events.jsonl"), run_id=run_id)],
        ),
    )
    print("RUN_ID", run_id)
    results = tuner.fit()
    best = results.get_best_result(metric=cfg.get("metric", "val_rmse"), mode=cfg.get("mode", "min"))
    print("BEST_RESULT", best.metrics)
    print("BEST_CONFIG", best.config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
