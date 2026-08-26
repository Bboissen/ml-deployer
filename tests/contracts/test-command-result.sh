#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate-command-result.sh"
contracts="$repo_root/shared/contracts"
fixtures="$contracts/command-fixtures"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

jq -e '
  .additionalProperties == false
  and (."$comment" | contains("validate-command-result.sh"))
  and .properties.checks.minItems == 1
  and (.allOf | length) >= 5
' "$contracts/command-result.schema.json" >/dev/null \
  || fail 'command-result schema lost a frozen safety constraint'

"$validator" "$fixtures/valid-doctor.json" >/dev/null \
  || fail 'valid doctor result was rejected'

invalid_fixtures=(
  "$fixtures/invalid-pass-failed-check.json"
  "$fixtures/invalid-null-destroy.json"
  "$fixtures/invalid-pass-null-scope.json"
  "$fixtures/invalid-secret-evidence.json"
)

for fixture in "${invalid_fixtures[@]}"; do
  [[ -f "$fixture" ]] || fail "required negative fixture is missing: $fixture"
  if "$validator" "$fixture" >/dev/null 2>&1; then
    fail "invalid command result accepted: $fixture"
  fi
done

printf 'Command-result tests passed: 1 valid and %d fail-closed fixtures.\n' "${#invalid_fixtures[@]}"
