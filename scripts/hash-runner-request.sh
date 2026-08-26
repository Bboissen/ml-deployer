#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s REQUEST.json\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly VALIDATOR="${SCRIPT_DIRECTORY}/validate-runner-request.sh"

if ! command -v sha256sum >/dev/null 2>&1; then
  printf 'ERROR: sha256sum is required to hash runner requests.\n' >&2
  exit 3
fi

# The validator emits the closed request as one jq -cS JSON line. Command
# substitution removes its line feed; the digest is over the remaining UTF-8
# bytes exactly, with no trailing line feed.
canonical_request="$($VALIDATOR "$1")"
printf '%s' "$canonical_request" | sha256sum | awk '{print $1}'
