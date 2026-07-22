#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-configs/tune_synthetic.yaml}"
if [ ! -f "$CONFIG" ]; then
  echo "Config file not found: $CONFIG" >&2
  exit 1
fi

mkdir -p artifacts/live artifacts/ray_results

if [ -n "${ML_REPO_PATH:-}" ]; then
  echo "ML_REPO_PATH is set: $ML_REPO_PATH"
  echo "This template does not assume private ML repo internals."
  echo "Set ML_RUN_COMMAND to run a project-specific command if needed."
fi

if [ -n "${ML_RUN_COMMAND:-}" ]; then
  echo "Running ML_RUN_COMMAND"
  # The command is intentionally user-provided for the separate ML repo boundary.
  # shellcheck disable=SC2086
  $ML_RUN_COMMAND
else
  echo "Running built-in synthetic Tune workload with $CONFIG"
  # shellcheck disable=SC1091
  [ -f .venv/bin/activate ] && source .venv/bin/activate
  python -m spotify_ray_infra.tune_synthetic --config "$CONFIG"
fi
