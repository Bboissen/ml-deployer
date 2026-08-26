#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate-deployment-index.sh"
fixtures="$repo_root/shared/contracts/index-fixtures"
request_fixture="$repo_root/shared/contracts/fixtures/valid-aws.json"
request_hasher="$repo_root/scripts/hash-runner-request.sh"

jq -e '
  .additionalProperties == false
  and (."$comment" | contains("validate-deployment-index.sh"))
' "$repo_root/shared/contracts/deployment-index.schema.json" >/dev/null

"$validator" "$fixtures/valid-aws.json" >/dev/null

expected_request_sha256="$($request_hasher "$request_fixture")"
recorded_request_sha256="$(jq -r '.request_sha256' "$fixtures/valid-aws.json")"
if [[ "$recorded_request_sha256" != "$expected_request_sha256" ]]; then
  printf 'FAIL: deployment index is not bound to the canonical AWS request hash\n' >&2
  exit 1
fi

if "$validator" "$fixtures/invalid-backend-binding.json" >/dev/null 2>&1; then
  printf 'FAIL: mismatched deployment-index backend key was accepted\n' >&2
  exit 1
fi

printf 'Deployment-index tests passed: backend key and canonical request hash are cross-bound.\n'
