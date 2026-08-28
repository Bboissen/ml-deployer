#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${TEST_DIRECTORY}/../.." && pwd -P)"
readonly DISPATCH="${REPOSITORY_ROOT}/scripts/dummy/dispatch.sh"
readonly TEST_PARENT="${REPOSITORY_ROOT}/.dummy-runtime"
mkdir -p "$TEST_PARENT"
readonly TEST_ROOT="$(mktemp -d "${TEST_PARENT}/operator-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'test-operator-interface: FAIL: %s\n' "$1" >&2
  exit 1
}

readonly HASH="$(printf exact-artifact | sha256sum | cut -d' ' -f1)"

for target in dummy-receipt-publish dummy-post-destroy-check; do
  grep -Eq "^${target}:" "${REPOSITORY_ROOT}/Makefile" || fail "missing Make target: ${target}"
done

if CLOUD=digitalocean "$DISPATCH" preflight >/dev/null 2>&1; then
  fail "unsupported cloud selection was accepted"
fi

if CLOUD=aws "$DISPATCH" plan >/dev/null 2>&1; then
  fail "plan without immutable hashes was accepted"
fi

if CLOUD=aws \
  PACKAGE_LOCK_SHA256="$HASH" \
  IMAGE_SOURCE_MANIFEST_SHA256="$HASH" \
  OCI_MANIFEST_DIGEST="sha256:${HASH}" \
  RUN_SPEC_SHA256="$HASH" \
  INPUT_SHA256="$HASH" \
  "$DISPATCH" preflight >/dev/null 2>&1; then
  fail "missing provider adapter was accepted"
fi

if CLOUD=aws "$DISPATCH" apply >/dev/null 2>&1; then
  fail "apply without a saved plan was accepted"
fi

if CLOUD=aws \
  PACKAGE_LOCK_SHA256="$HASH" \
  IMAGE_SOURCE_MANIFEST_SHA256="$HASH" \
  OCI_MANIFEST_DIGEST="sha256:${HASH}" \
  RUN_SPEC_SHA256="$HASH" \
  INPUT_SHA256="$HASH" \
  PUBLICATION_BUNDLE_SHA256="$HASH" \
  "$DISPATCH" publish >/dev/null 2>&1; then
  fail "publication hash without the actual bundle was accepted"
fi

if CLOUD=aws RECEIPT_BUNDLE_SHA256="$HASH" "$DISPATCH" receipt-publish >/dev/null 2>&1; then
  fail "receipt publication hash without the actual bundle was accepted"
fi

if CLOUD=aws "$DISPATCH" post-destroy-check >/dev/null 2>&1; then
  fail "post-destroy verification without a deployment ID was accepted"
fi

printf exact-artifact >"${TEST_ROOT}/saved-plan.bin"
printf '%s\n' \
  '{"artifact_sha256":"0000000000000000000000000000000000000000000000000000000000000000","authorization":"APPLY EXACT ARTIFACT sha256:0000000000000000000000000000000000000000000000000000000000000000 FOR aws","operation":"apply","provider":"aws","schema_version":"1.0.0"}' \
  >"${TEST_ROOT}/wrong-authorization.json"
if CLOUD=aws \
  SAVED_PLAN="${TEST_ROOT}/saved-plan.bin" \
  SAVED_PLAN_SHA256="$HASH" \
  APPLY_AUTHORIZATION="${TEST_ROOT}/wrong-authorization.json" \
  "$DISPATCH" apply >/dev/null 2>&1; then
  fail "wrong exact authorization artifact was accepted"
fi

if rg -n '(^|[[:space:]])(tofu|terraform)[[:space:]]+plan' \
    "$DISPATCH" "${REPOSITORY_ROOT}/Makefile" >/dev/null; then
  fail "shared apply surface contains an implicit plan command"
fi

printf 'Dummy operator interface fail-closed tests passed. No provider adapter or cloud command ran.\n'
