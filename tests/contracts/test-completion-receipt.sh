#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate-completion-receipt.sh"
contracts="$repo_root/shared/contracts"
fixtures="$contracts/receipt-fixtures"
request_hasher="$repo_root/scripts/hash-runner-request.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

jq -e '
  .additionalProperties == false
  and (."$comment" | contains("provider-authenticated publication metadata"))
  and .properties.terminal.const == true
  and .properties.publication_mode.const == "control_identity_conditional_create"
  and (.required | index("container_exit_code") != null)
  and (.required | index("backend_key") != null)
  and (.required | index("request_sha256") != null)
  and (.required | index("platform_contract_sha256") != null)
  and (.required | index("receipt_publisher_identity") != null)
  and (.required | index("control_evidence_sha256") != null)
  and (.required | index("control_evidence_uri") != null)
  and (.required | index("result_manifest_sha256") == null)
  and (.properties | has("result_manifest_sha256"))
  and (.required | index("log_sha256") != null)
' "$contracts/completion-receipt.schema.json" >/dev/null \
  || fail 'completion receipt schema lost a frozen terminal-evidence constraint'

valid_fixtures=(
  "$fixtures/valid-aws.json"
  "$fixtures/valid-gcp.json"
  "$fixtures/valid-azure.json"
  "$fixtures/valid-bootstrap-failed-aws.json"
)

for fixture in "${valid_fixtures[@]}"; do
  "$validator" "$fixture" >/dev/null \
    || fail "valid completion receipt was rejected: $fixture"
done

for provider in aws gcp azure; do
  request_fixture="$contracts/fixtures/valid-${provider}.json"
  receipt_fixture="$fixtures/valid-${provider}.json"
  [[ "$(jq -r '.request_sha256' "$receipt_fixture")" == "$($request_hasher "$request_fixture")" ]] \
    || fail "valid completion receipt is not bound to the canonical ${provider} request hash"
done

invalid_fixtures=(
  "$fixtures/invalid-backend-binding.json"
  "$fixtures/invalid-deadline-window.json"
  "$fixtures/invalid-profile-floor.json"
  "$fixtures/invalid-publisher-identity.json"
  "$fixtures/invalid-success-exit.json"
  "$fixtures/invalid-success-after-deadline.json"
  "$fixtures/invalid-terminal.json"
)

for fixture in "${invalid_fixtures[@]}"; do
  [[ -f "$fixture" ]] || fail "required negative fixture is missing: $fixture"
  if "$validator" "$fixture" >/dev/null 2>&1; then
    fail "invalid completion receipt accepted: $fixture"
  fi
done

printf 'Completion receipt tests passed: %d valid and %d fail-closed fixtures.\n' \
  "${#valid_fixtures[@]}" "${#invalid_fixtures[@]}"
