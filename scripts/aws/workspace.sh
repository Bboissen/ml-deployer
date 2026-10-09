#!/usr/bin/env bash
# Bootstrap before Python; retain the proven Python deployment engine.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"
if [[ "${1:-}" == setup ]]; then
  shift
  exec bash scripts/aws/workstation-setup.sh "$@"
fi
if [[ -z "${WORKSPACE_PYTHON:-}" ]]; then
  setup_options=()
  [[ "${1:-}" != github-login ]] || setup_options+=(--github)
  bash scripts/aws/workstation-setup.sh "${setup_options[@]}"
  tools_dir="${WORKSPACE_TOOLS_DIR:-$repo_root/.tools/aws-workstation}"
  export PATH="$tools_dir/current/bin:$tools_dir/current/sdk/bin:$PATH"
  export WORKSPACE_PYTHON="$tools_dir/current/sdk/bin/python"
fi
export PYTHONDONTWRITEBYTECODE=1
case "${1:-}" in
  login|auth-check|github-login) exec "$WORKSPACE_PYTHON" scripts/aws/workstation-auth.py "$@" 3<&0 ;;
esac
exec "${WORKSPACE_PYTHON:-python3}" scripts/aws/workspace.py "$@" 3<&0
