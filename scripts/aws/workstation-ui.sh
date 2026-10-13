# Shared terminal presentation for bootstrap and its first-use entry point.
ui_color() {
  if [[ -t 2 && "${TERM:-}" != dumb && -z "${NO_COLOR+x}" ]]; then
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
