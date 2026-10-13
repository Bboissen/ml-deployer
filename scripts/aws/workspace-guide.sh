#!/usr/bin/env bash
# First-use entry point (`make`): install or verify the managed tools, then serve
# the guide with live readiness on 127.0.0.1. No login, no cloud changes.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
config="${1:-$HOME/aws-workspace/demo/project.json}"
[[ "$config" == /* ]] || config="$PWD/$config"
python="${WORKSPACE_TOOLS_DIR:-$repo_root/.tools/aws-workstation}/current/sdk/bin/python"

if bash "$repo_root/workspace" setup && [[ -x "$python" ]]; then
  exec "$python" "$repo_root/scripts/aws/workspace-guide.py" "$config"
fi
# Without the managed tools there is no runtime to serve the page: show the repair step here.
printf '\nworkspace guide: the managed tools are needed before the guide page can open.\n\n' >&2
target=(); [[ ! -f "$config" ]] || target=("$config")
bash "$repo_root/workspace" doctor ${target[@]+"${target[@]}"} || true
exit 1
