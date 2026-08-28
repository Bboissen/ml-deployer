#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIRECTORY}/../.." && pwd -P)"
readonly PROVIDER_ROOT="${SCRIPT_DIRECTORY}/providers"

fail() {
  printf 'dummy-dispatch: ERROR: %s\n' "$1" >&2
  exit 2
}

require_sha256() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || fail "${name} must be an exact lowercase SHA-256"
}

require_oci_digest() {
  [[ "${OCI_MANIFEST_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "OCI_MANIFEST_DIGEST must be an exact sha256 digest"
}

require_regular_file() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || fail "${name} is required"
  [[ "$value" == /* ]] || fail "${name} must be an absolute durable path"
  [[ "$value" != /tmp/* ]] || fail "${name} may not be stored under /tmp"
  [[ -f "$value" && ! -L "$value" && -s "$value" ]] ||
    fail "${name} must name a non-empty regular non-symlink file"
}

verify_file_sha256() {
  local path_name="$1"
  local hash_name="$2"
  require_regular_file "$path_name"
  require_sha256 "$hash_name"
  [[ "$(sha256sum "${!path_name}" | cut -d' ' -f1)" == "${!hash_name}" ]] ||
    fail "${path_name} does not match ${hash_name}"
}

verify_authorization() {
  local path_name="$1"
  local operation="$2"
  local artifact_sha256="$3"
  local authorization_path="${!path_name}"
  local expected_sentence
  expected_sentence="${operation^^} EXACT ARTIFACT sha256:${artifact_sha256} FOR ${CLOUD}"
  require_regular_file "$path_name"
  jq -e \
    --arg operation "$operation" \
    --arg provider "$CLOUD" \
    --arg artifact_sha256 "$artifact_sha256" \
    --arg authorization "$expected_sentence" \
    'keys == ["artifact_sha256", "authorization", "operation", "provider", "schema_version"]
     and .schema_version == "1.0.0"
     and .operation == $operation
     and .provider == $provider
     and .artifact_sha256 == $artifact_sha256
     and .authorization == $authorization' \
    "$authorization_path" >/dev/null ||
    fail "${path_name} does not exactly authorize the reviewed ${operation} artifact"
}

require_contract_hashes() {
  require_sha256 PACKAGE_LOCK_SHA256
  require_sha256 IMAGE_SOURCE_MANIFEST_SHA256
  require_oci_digest
  require_sha256 RUN_SPEC_SHA256
  require_sha256 INPUT_SHA256
}

(( $# == 1 )) || fail "usage: $0 OPERATION"
readonly OPERATION="$1"
case "$OPERATION" in
  preflight|publication-review|publish|plan|apply|observe|receipt-publish|receipt-check|destroy-plan|destroy|post-destroy-check) ;;
  *) fail "unsupported operation: ${OPERATION}" ;;
esac

case "${CLOUD:-}" in
  aws|gcp|azure) ;;
  '') fail "CLOUD is required and must be aws, gcp, or azure" ;;
  *) fail "unsupported CLOUD selection: ${CLOUD}" ;;
esac

case "$OPERATION" in
  preflight|publication-review|publish|plan)
    require_contract_hashes
    ;;
esac

case "$OPERATION" in
  publish)
    verify_file_sha256 PUBLICATION_BUNDLE PUBLICATION_BUNDLE_SHA256
    verify_authorization PUBLICATION_AUTHORIZATION publish "$PUBLICATION_BUNDLE_SHA256"
    ;;
  apply)
    verify_file_sha256 SAVED_PLAN SAVED_PLAN_SHA256
    verify_authorization APPLY_AUTHORIZATION apply "$SAVED_PLAN_SHA256"
    ;;
  observe|destroy-plan|post-destroy-check)
    [[ "${DEPLOYMENT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{1,47}[a-z0-9]$ ]] ||
      fail "DEPLOYMENT_ID is required and invalid"
    ;;
  receipt-publish)
    verify_file_sha256 RECEIPT_BUNDLE RECEIPT_BUNDLE_SHA256
    verify_authorization RECEIPT_PUBLISH_AUTHORIZATION receipt-publish "$RECEIPT_BUNDLE_SHA256"
    ;;
  receipt-check)
    verify_file_sha256 FINAL_RECEIPT FINAL_RECEIPT_SHA256
    ;;
  destroy)
    verify_file_sha256 SAVED_PLAN SAVED_PLAN_SHA256
    verify_authorization DESTROY_AUTHORIZATION destroy "$SAVED_PLAN_SHA256"
    ;;
esac

readonly ADAPTER_PATH="${PROVIDER_ROOT}/${CLOUD}.sh"
[[ -x "$ADAPTER_PATH" && ! -L "$ADAPTER_PATH" ]] ||
  fail "provider adapter is missing or not executable: scripts/dummy/providers/${CLOUD}.sh"

exec "$ADAPTER_PATH" "$OPERATION"
