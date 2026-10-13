#!/usr/bin/env bash
# First use: verified tools, interactive project/login setup and an HTML companion.
set -euo pipefail
umask 077
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/scripts/aws/workstation-ui.sh"
config=''; setup_options=(); guide_options=(); debug=0
while (($#)); do
  case "$1" in
    --fresh) setup_options+=(--fresh) ;;
    --debug) setup_options+=(--debug); guide_options+=(--debug); debug=1 ;;
    --read-only) guide_options+=(--read-only) ;;
    --help) printf '%s\n' 'workspace guide [PROJECT.json] [--fresh] [--debug] [--read-only]'; exit 0 ;;
    -*) printf 'workspace guide: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) [[ -z "$config" ]] || { printf 'workspace guide: provide one project path\n' >&2; exit 2; }; config="$1" ;;
  esac
  shift
done
config="${config:-$HOME/aws-workspace/demo/project.json}"
[[ "$config" == /* ]] || config="$PWD/$config"
python="${WORKSPACE_TOOLS_DIR:-$repo_root/.tools/aws-workstation}/current/sdk/bin/python"
ui_title
ui_color '1;36' '  1/4  Tools'; printf '\n' >&2
ui_status run 'Checking and preparing pinned tools…'
setup_log="$(mktemp "${TMPDIR:-/tmp}/workspace-setup.XXXXXX")"
trap 'rm -f "$setup_log"' EXIT
if bash "$repo_root/workspace" setup ${setup_options[@]+"${setup_options[@]}"} >"$setup_log" 2>&1 && [[ -x "$python" ]]; then
  (( !debug )) || cat "$setup_log" >&2
  ui_status done 'Tools ready'
  rm -f "$setup_log"; trap - EXIT
  export WORKSPACE_GUIDE_TITLE_SHOWN=1 PYTHONDONTWRITEBYTECODE=1
  export PATH="${WORKSPACE_TOOLS_DIR:-$repo_root/.tools/aws-workstation}/current/bin:$PATH"
  cd "$repo_root"
  exec "$python" "$repo_root/scripts/aws/workspace-guide.py" "$config" ${guide_options[@]+"${guide_options[@]}"}
fi
# Without the managed tools there is no runtime to serve the page: show the repair step here.
ui_status error 'The managed tools are needed before the guide page can open'
cat "$setup_log" >&2
target=(); [[ ! -f "$config" ]] || target=("$config")
bash "$repo_root/workspace" doctor ${target[@]+"${target[@]}"} || true
exit 1
