#!/usr/bin/env bash
# Keep the existing entrypoint; Python owns configuration and orchestration.
set -euo pipefail
exec "${WORKSPACE_PYTHON:-python3}" scripts/aws/workspace.py "$@" 3<&0
