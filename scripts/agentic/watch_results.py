#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def read_events(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    out: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def latest_run(events: list[dict[str, Any]]) -> tuple[str | None, list[dict[str, Any]]]:
    run_id = None
    for ev in events:
        value = ev.get("run_id")
        if value:
            run_id = str(value)
    if not run_id:
        return None, events
    return run_id, [ev for ev in events if ev.get("run_id") == run_id]


def write_summary(events: list[dict[str, Any]], out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    run_id, selected_events = latest_run(events)
    by_trial: dict[str, dict[str, Any]] = {}
    failures = []
    for ev in selected_events:
        if ev.get("event") == "trial_result":
            trial_id = str(ev.get("trial_id", "unknown"))
            by_trial[trial_id] = ev
        elif ev.get("event") in {"trial_error", "trial_terminated"} and ev.get("error"):
            failures.append(ev)

    metric_name = None
    rows = []
    for trial_id, ev in by_trial.items():
        metrics = ev.get("metrics", {}) or {}
        if not metric_name:
            for key in ["val_rmse", "rmse", "loss", "score"]:
                if key in metrics:
                    metric_name = key
                    break
        value = metrics.get(metric_name) if metric_name else None
        rows.append((trial_id, value, ev))

    if metric_name:
        rows.sort(key=lambda x: float("inf") if x[1] is None else float(x[1]))

    now = datetime.now(timezone.utc).isoformat()
    lines = [
        "# Live Ray Tune Summary",
        "",
        f"Generated UTC: `{now}`",
        f"Events seen: `{len(events)}`",
        f"Run id: `{run_id or 'unscoped legacy events'}`",
        f"Events in selected run: `{len(selected_events)}`",
        f"Trials with latest results: `{len(by_trial)}`",
        f"Metric used for ordering: `{metric_name or 'unknown'}`",
        "",
        "## Top trials",
        "",
        "| Rank | Trial | Metric | Last iteration | Node |",
        "|---:|---|---:|---:|---|",
    ]
    for rank, (trial_id, value, ev) in enumerate(rows[:10], start=1):
        metrics = ev.get("metrics", {}) or {}
        node = ev.get("node", "")
        it = metrics.get("training_iteration", metrics.get("iteration", ""))
        lines.append(f"| {rank} | `{trial_id}` | `{value}` | `{it}` | `{node}` |")

    lines += ["", "## Recent events", ""]
    for ev in selected_events[-20:]:
        lines.append(f"- `{ev.get('ts_utc', '')}` `{ev.get('event', '')}` trial=`{ev.get('trial_id', '')}`")

    if failures:
        lines += ["", "## Failures", ""]
        for ev in failures[-10:]:
            lines.append(f"- `{ev.get('ts_utc', '')}` trial=`{ev.get('trial_id', '')}` error=`{ev.get('error', '')}`")

    out.write_text("\n".join(lines) + "\n", encoding="utf-8")


def maybe_trigger(report_path: Path) -> None:
    command = os.environ.get("CODEX_REVIEW_COMMAND", "").strip()
    if not command:
        return
    subprocess.run(["bash", "scripts/agentic/review_latest_results.sh", str(report_path)], check=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", default="artifacts/live/trial_events.jsonl")
    parser.add_argument("--out", default="artifacts/live/latest_summary.md")
    parser.add_argument("--interval", type=float, default=10.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--trigger", action="store_true")
    args = parser.parse_args()

    events_path = Path(args.events)
    out_path = Path(args.out)
    last_count = -1
    while True:
        events = read_events(events_path)
        if len(events) != last_count:
            write_summary(events, out_path)
            last_count = len(events)
            if args.trigger:
                maybe_trigger(out_path)
        if args.once:
            break
        time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
