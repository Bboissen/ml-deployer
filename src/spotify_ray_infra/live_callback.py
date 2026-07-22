from __future__ import annotations

import json
import os
import socket
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from ray.tune import Callback
except Exception:  # pragma: no cover
    Callback = object  # type: ignore[misc,assignment]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class LiveJsonlCallback(Callback):
    """Write Ray Tune trial events to JSONL for real-time review."""

    def __init__(self, path: str = "artifacts/live/trial_events.jsonl", run_id: str | None = None) -> None:
        self.path = Path(path)
        self.run_id = run_id or os.environ.get("RAY_TUNE_RUN_ID", "").strip() or _now()
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _write(self, event: dict[str, Any]) -> None:
        event.setdefault("ts_utc", _now())
        event.setdefault("run_id", self.run_id)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event, sort_keys=True, default=str) + "\n")

    def on_trial_result(self, iteration: int, trials: list[Any], trial: Any, result: dict[str, Any], **info: Any) -> None:
        metrics = {k: v for k, v in result.items() if isinstance(v, (int, float, str, bool)) or v is None}
        self._write(
            {
                "event": "trial_result",
                "iteration": iteration,
                "trial_id": getattr(trial, "trial_id", str(trial)),
                "node": result.get("node_ip") or result.get("hostname") or socket.gethostname(),
                "metrics": metrics,
                "config": getattr(trial, "config", {}),
            }
        )

    def on_trial_error(self, iteration: int, trials: list[Any], trial: Any, **info: Any) -> None:
        self._write(
            {
                "event": "trial_error",
                "iteration": iteration,
                "trial_id": getattr(trial, "trial_id", str(trial)),
                "error": str(info.get("error", "")),
            }
        )

    def on_trial_complete(self, iteration: int, trials: list[Any], trial: Any, **info: Any) -> None:
        self._write(
            {
                "event": "trial_complete",
                "iteration": iteration,
                "trial_id": getattr(trial, "trial_id", str(trial)),
            }
        )
