#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'deadline-marker: %s\n' "$1" >&2
  exit "${2:-64}"
}

(( $# >= 3 )) || fail "usage: deadline-marker.sh MARKER -- COMMAND [ARGUMENT ...]"
readonly MARKER_PATH="$1"
shift
[[ "$1" == "--" ]] || fail "the command must follow --"
shift
(( $# >= 1 )) || fail "a command is required"

[[ "$MARKER_PATH" == /* ]] || fail "marker path must be absolute"
[[ ! -e "$MARKER_PATH" && ! -L "$MARKER_PATH" ]] || fail "marker already exists"
[[ -d "${MARKER_PATH%/*}" && -w "${MARKER_PATH%/*}" ]] || fail "marker directory is not writable"
[[ ! -L "${MARKER_PATH%/*}" ]] || fail "marker directory may not be a symbolic link"

mark_deadline() {
  trap - TERM
  umask 077
  if ! (set -o noclobber; : >"$MARKER_PATH") 2>/dev/null; then
    exit 125
  fi
  kill -TERM "$CHILD_PID" 2>/dev/null || true
}
trap mark_deadline TERM

"$@" &
readonly CHILD_PID=$!

while kill -0 "$CHILD_PID" 2>/dev/null; do
  set +e
  wait "$CHILD_PID"
  child_exit_code=$?
  set -e
done

# Reap the child and retain its terminal status if the signal-interrupted wait
# above returned before the child actually exited.
set +e
wait "$CHILD_PID" 2>/dev/null
reaped_exit_code=$?
set -e
if ((reaped_exit_code != 127)); then
  child_exit_code=$reaped_exit_code
fi

trap - TERM
exit "$child_exit_code"
