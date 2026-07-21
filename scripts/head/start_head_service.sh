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
if [ -z "$RAY_HEAD_TS_IP" ]; then
  printf 'RAY_HEAD_TS_IP is required for scoped head startup.\n' >&2
  exit 1
fi
if systemctl --user is-active --quiet "$UNIT"; then
  printf '%s is already active.\n' "$UNIT" >&2
  exit 1
fi
if nc -z -w 2 "$RAY_HEAD_TS_IP" "$RAY_HEAD_PORT" 2>/dev/null; then
  printf 'Refusing startup: %s:%s is already in use.\n' "$RAY_HEAD_TS_IP" "$RAY_HEAD_PORT" >&2
  exit 1
fi

systemctl --user reset-failed "$UNIT" 2>/dev/null || true
systemd-run --user \
  --unit="$UNIT" \
  --collect \
  --property=Type=exec \
  --property=KillMode=control-group \
  --property=TimeoutStopSec=30s \
  --working-directory="$ROOT_DIR" \
  /usr/bin/bash "$ROOT_DIR/scripts/head/start_head.sh"

for _ in $(seq 1 60); do
  if ! systemctl --user is-active --quiet "$UNIT"; then
    printf 'Scoped Ray head unit exited before becoming ready.\n' >&2
    systemctl --user status "$UNIT" --no-pager >&2 || true
    exit 1
  fi
  if nc -z -w 1 "$RAY_HEAD_TS_IP" "$RAY_HEAD_PORT" 2>/dev/null; then
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
      printf 'Scoped Ray head ownership evidence is invalid for %s.\n' "$UNIT" >&2
      systemctl --user stop "$UNIT"
      exit 1
    fi
    printf 'Ray head ready at %s:%s in %s.\n' "$RAY_HEAD_TS_IP" "$RAY_HEAD_PORT" "$control_group"
    exit 0
  fi
  sleep 1
done

printf 'Scoped Ray head did not become ready within 60 seconds.\n' >&2
systemctl --user stop "$UNIT"
exit 1
