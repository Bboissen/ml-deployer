#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate-runner-request.sh"
contracts="$repo_root/shared/contracts"
fixtures="$contracts/fixtures"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for json_file in "$contracts"/*.json "$fixtures"/*.json; do
  jq -e . "$json_file" >/dev/null || fail "invalid JSON: $json_file"
done

jq -e '
  .additionalProperties == false
  and (."$comment" | startswith("Structural schema."))
  and .properties.capacity_mode.const == "standard"
  and .properties.maximum_runtime_minutes.minimum == 15
  and .properties.maximum_runtime_minutes.maximum == 720
' "$contracts/runner-request.schema.json" >/dev/null \
  || fail 'runner request schema lost a frozen safety constraint'

jq -e '
  .additionalProperties == false
  and (."$comment" | startswith("Structural schema."))
  and (.required | index("terminal") != null)
  and .properties.terminal.const == true
' "$contracts/completion-receipt.schema.json" >/dev/null \
  || fail 'completion receipt schema is not terminal and closed'

valid_fixtures=(
  "$fixtures/valid-aws.json"
  "$fixtures/valid-gcp.json"
  "$fixtures/valid-azure.json"
)

for fixture in "${valid_fixtures[@]}"; do
  "$validator" "$fixture" >/dev/null \
    || fail "valid fixture rejected: $fixture"
done

invalid_fixtures=(
  "$fixtures/invalid-arbitrary-shell.json"
  "$fixtures/invalid-deployment-id.json"
  "$fixtures/invalid-fractional-runtime.json"
  "$fixtures/invalid-interruptible.json"
  "$fixtures/invalid-mutable-tag.json"
  "$fixtures/invalid-provider-binding.json"
  "$fixtures/invalid-secret-field.json"
  "$fixtures/invalid-signed-uri.json"
  "$fixtures/invalid-unbounded-runtime.json"
)

invalid_count=0
for fixture in "${invalid_fixtures[@]}"; do
  [[ -f "$fixture" ]] || fail "required negative fixture is missing: $fixture"
  invalid_count=$((invalid_count + 1))
  if "$validator" "$fixture" >/dev/null 2>&1; then
    fail "invalid fixture accepted: $fixture"
  fi
done
[[ $invalid_count -eq 9 ]] || fail 'expected exactly nine named invalid fixtures'

temporary_directory="$(mktemp -d)"
trap 'find "$temporary_directory" -depth -delete' EXIT

jq '.oci_repository = (.oci_repository + ("a" * 256))' \
  "$fixtures/valid-aws.json" >"$temporary_directory/overlong-repository.json"
if "$validator" "$temporary_directory/overlong-repository.json" >/dev/null 2>&1; then
  fail 'validator accepted an OCI repository over the schema maximum'
fi

jq '.run_spec_uri = (.run_spec_uri | sub("/run-specs/"; "/" + ("a" * 2048) + "/run-specs/"))' \
  "$fixtures/valid-aws.json" >"$temporary_directory/overlong-uri.json"
if "$validator" "$temporary_directory/overlong-uri.json" >/dev/null 2>&1; then
  fail 'validator accepted a run-spec URI over the schema maximum'
fi

jq --arg object_version $'invalid\001version' '.run_spec_object_version = $object_version' \
  "$fixtures/valid-aws.json" >"$temporary_directory/control-character-version.json"
if "$validator" "$temporary_directory/control-character-version.json" >/dev/null 2>&1; then
  fail 'validator accepted a control character in the provider object version'
fi

common_projection='{
  schema_version,
  deployment_id,
  oci_digest,
  run_spec_sha256,
  resource_profile,
  capacity_mode,
  maximum_runtime_minutes
}'
reference_projection="$(jq -cS "$common_projection" "${valid_fixtures[0]}")"
for fixture in "${valid_fixtures[@]:1}"; do
  [[ "$(jq -cS "$common_projection" "$fixture")" == "$reference_projection" ]] \
    || fail "provider fixtures do not share one semantic request: $fixture"
done

providers="$(jq -r '.provider' "${valid_fixtures[@]}" | LC_ALL=C sort | paste -sd, -)"
[[ "$providers" == 'aws,azure,gcp' ]] \
  || fail "expected exactly one valid fixture per provider, got: $providers"

for fixture in "${valid_fixtures[@]}"; do
  deployment_id="$(jq -r '.deployment_id' "$fixture")"
  run_spec_sha256="$(jq -r '.run_spec_sha256' "$fixture")"
  run_spec_uri="$(jq -r '.run_spec_uri' "$fixture")"
  [[ "$run_spec_uri" == *"/run-specs/$deployment_id/$run_spec_sha256.json" ]] \
    || fail "run-spec URI is not immutable and content-addressed: $fixture"
done

printf 'Runner contract tests passed: 3 valid provider fixtures and %d fail-closed fixtures.\n' "$invalid_count"
