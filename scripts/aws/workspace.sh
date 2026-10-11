#!/usr/bin/env bash
# Preserve the existing command path for scripts and installed releases.
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/../../workspace" "$@"
