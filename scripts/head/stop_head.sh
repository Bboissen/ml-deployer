#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
[ -f .venv/bin/activate ] && source .venv/bin/activate
ray stop --force || true
