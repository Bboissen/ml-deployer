#!/usr/bin/env bash
set -euo pipefail

read -r -a python_cmd <<< "${PYTHON_BIN:-python3}"
"${python_cmd[@]}" --version >/dev/null

"${python_cmd[@]}" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -U pip wheel
pip install -r requirements.txt
pip install -e .

if ! command -v tailscale >/dev/null; then
  echo "WARNING: tailscale is not installed or not in PATH. Install it on the home server before starting Ray head." >&2
fi

mkdir -p artifacts/live artifacts/ray_results artifacts/reviews artifacts/inbox logs
