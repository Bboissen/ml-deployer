#!/usr/bin/env bash
# First-use entry point (`make`): install or verify the managed tools, record
# doctor readiness for the guide page and open it. No login, no cloud changes.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
config="${1:-$HOME/aws-workspace/demo/project.json}"
[[ "$config" == /* ]] || config="$PWD/$config"
page="$repo_root/docs/aws-setup-guide.html"
status_dir="$repo_root/.tools/guide"
mkdir -p "$status_dir"
partial="$(mktemp "$status_dir/status.js.XXXXXX")"
trap 'rm -f "$partial"' EXIT

bash "$repo_root/workspace" setup || printf 'workspace guide: setup needs attention; the guide shows the next command\n' >&2
target=(); [[ ! -f "$config" ]] || target=("$config")
report="$(bash "$repo_root/workspace" doctor --json ${target[@]+"${target[@]}"} 2>/dev/null)" || true
[[ "$report" == '{'* ]] || report=null
printf 'window.WORKSPACE_STATUS = %s;\n' "$report" > "$partial"
mv -f "$partial" "$status_dir/status.js"

opener=''
if [[ "$(uname -s)" == Darwin ]]; then opener=open
elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then opener=xdg-open
fi
if [[ -n "$opener" ]] && "$opener" "$page" >/dev/null 2>&1; then
  printf 'workspace guide: opened %s\nRun make (or ./workspace guide) again after each step to refresh it.\n' "$page"
else
  printf 'workspace guide: open %s in a browser; readiness now:\n\n' "$page"
  bash "$repo_root/workspace" doctor ${target[@]+"${target[@]}"} || true
fi
