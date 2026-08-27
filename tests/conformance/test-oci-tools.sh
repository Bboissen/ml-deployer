#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${TEST_DIRECTORY}/../.." && pwd -P)"
readonly VERIFY_SCRIPT="${REPOSITORY_ROOT}/scripts/oci/verify-provider-digests.sh"
readonly BUILD_SCRIPT="${REPOSITORY_ROOT}/scripts/oci/build-conformance-image.sh"
readonly FAKE_DOCKER="${TEST_DIRECTORY}/fixtures/docker"

fail() {
  printf 'test-oci-tools: FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -x "$FAKE_DOCKER" ]] || fail "fake docker fixture is not executable"
readonly FAKE_PATH="${TEST_DIRECTORY}/fixtures:/usr/bin:/bin"

readonly MANIFEST_DIGEST="sha256:$(printf '{"schemaVersion":2}' | sha256sum | cut -d' ' -f1)"
verification_output="$({
  PATH="$FAKE_PATH" "$VERIFY_SCRIPT" \
    "$MANIFEST_DIGEST" \
    "123456789012.dkr.ecr.us-east-1.amazonaws.com/demo/runner" \
    "us-central1-docker.pkg.dev/example-project/demo/runner" \
    "exampleml.azurecr.io/demo/runner"
})" || fail "identical fake registry manifests were rejected"
grep -Fq 'All provider-local repositories expose identical manifest bytes.' <<<"$verification_output" ||
  fail "verification success receipt is missing"

if PATH="$FAKE_PATH" "$VERIFY_SCRIPT" \
  "$MANIFEST_DIGEST" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/demo/runner:latest" \
  "us-central1-docker.pkg.dev/example-project/demo/runner" \
  "exampleml.azurecr.io/demo/runner" >/dev/null 2>&1; then
  fail "tagged ECR input was accepted"
fi

grep -Fq -- '--load' "$BUILD_SCRIPT" || fail "local build does not import its result"
if grep -Eq -- '--push|docker[[:space:]]+push|docker[[:space:]]+run' "$BUILD_SCRIPT"; then
  fail "local build script contains a push or workload run"
fi

printf 'OCI build/registry tool tests passed with fakes. No image or cloud command was executed.\n'
