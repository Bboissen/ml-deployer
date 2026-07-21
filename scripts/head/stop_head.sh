#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT="spotify-ray-head.service"

if [ -f "$ROOT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
fi

RAY_HEAD_TS_IP="${RAY_HEAD_TS_IP:-}"
RAY_HEAD_PORT="${RAY_HEAD_PORT:-6379}"

if ! systemctl --user is-active --quiet "$UNIT"; then
  if [ -n "$RAY_HEAD_TS_IP" ] && nc -z -w 2 "$RAY_HEAD_TS_IP" "$RAY_HEAD_PORT" 2>/dev/null; then
    printf 'Refusing broad teardown: %s:%s is open but %s is not active.\n' \
      "$RAY_HEAD_TS_IP" "$RAY_HEAD_PORT" "$UNIT" >&2
    exit 1
  fi
  printf '%s is not active; nothing owned by this repository was stopped.\n' "$UNIT"
  exit 0
fi

control_group="$(systemctl --user show "$UNIT" --property=ControlGroup --value)"
working_directory="$(systemctl --user show "$UNIT" --property=WorkingDirectory --value)"
exec_start="$(systemctl --user show "$UNIT" --property=ExecStart --value)"
exec_path="$(sed -n 's/^{ path=\([^ ;]*\) ;.*$/\1/p' <<<"$exec_start")"
exec_argv="$(sed -n 's/^.* ; argv\[\]=\(.*\) ; ignore_errors=.*$/\1/p' <<<"$exec_start")"
kill_mode="$(systemctl --user show "$UNIT" --property=KillMode --value)"
if [[ "$control_group" != */"$UNIT" || "$working_directory" != "$ROOT_DIR" ||
      "$exec_path" != "/usr/bin/bash" ||
      "$exec_argv" != "/usr/bin/bash $ROOT_DIR/scripts/head/start_head.sh" ||
      "$kill_mode" != "control-group" ]]; then
  printf 'Refusing teardown: %s ownership evidence does not match this repository.\n' "$UNIT" >&2
  exit 1
fi

systemctl --user stop "$UNIT"
if systemctl --user is-active --quiet "$UNIT"; then
  printf 'Scoped Ray head unit did not stop: %s\n' "$UNIT" >&2
  exit 1
fi
if [ -n "$RAY_HEAD_TS_IP" ] && nc -z -w 2 "$RAY_HEAD_TS_IP" "$RAY_HEAD_PORT" 2>/dev/null; then
  printf 'Scoped unit stopped but Ray head port remains open: %s:%s\n' "$RAY_HEAD_TS_IP" "$RAY_HEAD_PORT" >&2
  exit 1
fi
printf 'Stopped only %s (%s, %s).\n' "$UNIT" "$control_group" "$exec_start"
