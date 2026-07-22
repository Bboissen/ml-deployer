#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEAD_DIR="$ROOT_DIR/scripts/head"

if grep -n -E 'ray[[:space:]]+stop' \
  "$HEAD_DIR/start_head.sh" "$HEAD_DIR/start_head_service.sh" "$HEAD_DIR/stop_head.sh"; then
  printf 'Unsafe host-global ray stop remains under scripts/head.\n' >&2
  exit 1
fi
grep -Fq -- '--unit="$UNIT"' "$HEAD_DIR/start_head_service.sh"
grep -Fq -- '--property=KillMode=control-group' "$HEAD_DIR/start_head_service.sh"
grep -Fq -- '/usr/bin/bash "$ROOT_DIR/scripts/head/start_head.sh"' "$HEAD_DIR/start_head_service.sh"
grep -Fq -- 'systemctl --user stop "$UNIT"' "$HEAD_DIR/stop_head.sh"
grep -Fq -- 'WorkingDirectory' "$HEAD_DIR/stop_head.sh"
grep -Fq -- 'ExecStart' "$HEAD_DIR/stop_head.sh"
grep -Fq -- 'KillMode' "$HEAD_DIR/stop_head.sh"
grep -Fq -- '--block' "$HEAD_DIR/start_head.sh"

printf 'Head lifecycle policy: PASS (named unit, control-group kill, no host-global ray stop).\n'
