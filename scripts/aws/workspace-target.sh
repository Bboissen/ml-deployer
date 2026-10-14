#!/usr/bin/env bash
# Compatibility entry point; implementation is an importable Python module.
set -euo pipefail
exec "${WORKSPACE_PYTHON:-python3}" "$(dirname "${BASH_SOURCE[0]}")/workspace_target.py" "$@" 3<&0
