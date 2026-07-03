#!/usr/bin/env bash
set -euo pipefail

EXPECTED_WORKERS="${1:-0}"
# shellcheck disable=SC1091
[ -f .venv/bin/activate ] && source .venv/bin/activate
ray status

if [ "$EXPECTED_WORKERS" != "0" ]; then
  python -m spotify_ray_infra.smoke --expected-workers "$EXPECTED_WORKERS" --status-only
fi
