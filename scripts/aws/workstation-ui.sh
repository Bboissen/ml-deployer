# Shared terminal presentation for bootstrap and its first-use entry point.
ui_terminal() { [[ ( -t 2 || -t 0 ) && "${TERM:-}" != dumb ]]; }
ui_color() {
  if ui_terminal && [[ -z "${NO_COLOR+x}" ]]; then
    printf '\033[%sm%s\033[0m' "$1" "$2" >&2
  else printf '%s' "$2" >&2; fi
}
ui_status() {
  local mark color
  case "$1" in
    done) mark='✓'; color=32 ;;
    run) mark='›'; color=36 ;;
    error) mark='!'; color=31 ;;
    wait) mark='○'; color=33 ;;
  esac
  printf '  ' >&2; ui_color "$color" "$mark"; printf ' %s\n' "$2" >&2
}
ui_title() {
  printf '\n' >&2; ui_color '1;36' 'AWS workspace'; printf '\n' >&2
  ui_color 90 '  Setup on this machine · Ctrl+C to stop'; printf '\n\n' >&2
}
ui_busy_start() {
  ui_busy_pid=''
  if ! ui_terminal; then ui_status run "$1"; return; fi
  (
    trap 'exit 0' INT TERM
    local frames='|/-\' frame=0 started=$SECONDS
    while :; do
      printf '\r\033[2K  ' >&2
      ui_color 36 "${frames:frame%4:1}"
      printf ' %s  %ss' "$1" "$((SECONDS-started))" >&2
      frame=$((frame+1)); sleep 0.1
    done
  ) &
  ui_busy_pid=$!
}
ui_busy_stop() {
  if [[ -n "${ui_busy_pid:-}" ]]; then
    kill "$ui_busy_pid" 2>/dev/null || true
    wait "$ui_busy_pid" 2>/dev/null || true
    ui_busy_pid=''
    printf '\r\033[2K' >&2
  fi
}
