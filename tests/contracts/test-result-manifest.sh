#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${TEST_DIRECTORY}/../.." && pwd -P)"
readonly SCHEMA="${REPOSITORY_ROOT}/shared/contracts/result-manifest.schema.json"
readonly FIXTURE="${REPOSITORY_ROOT}/shared/contracts/result-manifest-fixtures/valid-conformance.json"
readonly VALIDATOR="${REPOSITORY_ROOT}/scripts/validate-result-manifest.sh"

fail() {
  printf 'test-result-manifest: FAIL: %s\n' "$1" >&2
  exit 1
}

jq -e '
  .additionalProperties == false
  and .properties.artifacts.minItems == 1
  and .properties.artifacts.maxItems == 64
  and .properties.artifacts.items.additionalProperties == false
  and (."$comment" | contains("sorted unique safe paths"))
' "$SCHEMA" >/dev/null || fail "schema lost a canonical result constraint"

canonical="$($VALIDATOR "$FIXTURE")" || fail "valid conformance manifest was rejected"
[[ "$canonical" == "$(jq -cS . "$FIXTURE")" ]] || fail "validator output is not canonical JSON"

readonly TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'find "$TEMPORARY_DIRECTORY" -depth -delete' EXIT

assert_mutation_rejected() {
  local name="$1"
  local jq_filter="$2"
  local path="${TEMPORARY_DIRECTORY}/${name}.json"
  jq "$jq_filter" "$FIXTURE" >"$path"
  if "$VALIDATOR" "$path" >/dev/null 2>&1; then
    fail "invalid mutation was accepted: ${name}"
  fi
}

assert_mutation_rejected unsorted '.artifacts |= reverse'
assert_mutation_rejected duplicate-path '.artifacts[1].path = .artifacts[0].path'
assert_mutation_rejected traversal '.artifacts[0].path = "../escape.parquet"'
assert_mutation_rejected self-reference '.artifacts[0].path = "result-manifest.json"'
assert_mutation_rejected extra-field '.unexpected = true'
assert_mutation_rejected zero-bytes '.artifacts[0].bytes = 0'

printf 'Result-manifest tests passed: 1 valid and 6 fail-closed mutations.\n'
