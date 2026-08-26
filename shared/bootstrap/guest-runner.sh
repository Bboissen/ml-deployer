#!/usr/bin/env bash

set -euo pipefail

readonly RECEIPT_SCHEMA_VERSION="1.0.0"
readonly RECEIPT_FILENAME="execution-receipt.local.json"

fail() {
  printf 'guest-runner: %s\n' "$1" >&2
  exit "${2:-64}"
}

require_environment() {
  local name="$1"
  [[ -v "$name" && -n "${!name}" ]] || fail "required environment variable ${name} is missing"
}

has_control_character() {
  local value="$1"
  [[ "$value" =~ [[:cntrl:]] ]]
}

validate_uri() {
  local name="$1"
  local value="${!name}"

  (( ${#value} <= 2048 )) || fail "${name} exceeds 2048 characters"
  has_control_character "$value" && fail "${name} contains a control character"
  [[ "$value" != *[[:space:]]* ]] || fail "${name} contains whitespace"
  [[ "$value" != *'?'* && "$value" != *'#'* && "$value" != *'@'* ]] ||
    fail "${name} may not contain credentials, a query, or a fragment"
  [[ "$value" =~ ^[a-z][a-z0-9+.-]*://[^/]+/.*$ ]] ||
    fail "${name} must be an absolute object URI"
}

json_string() {
  local value="$1"

  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

emit_receipt() {
  local status="$1"
  local exit_code="$2"
  local finished_at_utc="$3"
  local temporary_receipt

  temporary_receipt="$(mktemp -- "${ML_RECEIPT_OUTPUT_DIRECTORY}/.execution-receipt.XXXXXX.tmp")" ||
    return 1

  RECEIPT_TEMPORARY_PATH="$temporary_receipt"
  chmod 0600 -- "$temporary_receipt"

  {
    printf '{\n'
    printf '  "schema_version": %s,\n' "$(json_string "$RECEIPT_SCHEMA_VERSION")"
    printf '  "receipt_kind": "local_execution",\n'
    printf '  "execution_terminal": true,\n'
    printf '  "deployment_id": %s,\n' "$(json_string "$ML_DEPLOYMENT_ID")"
    printf '  "provider": %s,\n' "$(json_string "$ML_CLOUD_PROVIDER")"
    printf '  "oci_repository": %s,\n' "$(json_string "$ML_OCI_REPOSITORY")"
    printf '  "oci_digest": %s,\n' "$(json_string "$ML_OCI_DIGEST")"
    printf '  "run_spec_uri": %s,\n' "$(json_string "$ML_RUN_SPEC_URI")"
    printf '  "run_spec_sha256": %s,\n' "$(json_string "$ML_RUN_SPEC_SHA256")"
    printf '  "run_spec_object_version": %s,\n' "$(json_string "$ML_RUN_SPEC_OBJECT_VERSION")"
    printf '  "data_uri": %s,\n' "$(json_string "$ML_DATA_URI")"
    printf '  "results_uri": %s,\n' "$(json_string "$ML_RESULTS_URI")"
    printf '  "maximum_runtime_minutes": %d,\n' "$ML_MAX_RUNTIME_MINUTES"
    printf '  "started_at_utc": %s,\n' "$(json_string "$STARTED_AT_UTC")"
    printf '  "finished_at_utc": %s,\n' "$(json_string "$finished_at_utc")"
    printf '  "status": %s,\n' "$(json_string "$status")"
    printf '  "container_exit_code": %d\n' "$exit_code"
    printf '}\n'
  } >"$temporary_receipt" || return 1

  # A hard-link publication is atomic and fails closed if the final receipt
  # already exists. Both paths are in the same caller-provided directory.
  ln -- "$temporary_receipt" "$RECEIPT_PATH" || return 1
  rm -- "$temporary_receipt"
  RECEIPT_TEMPORARY_PATH=""
}

(( $# == 0 )) || fail "positional arguments are not accepted"

for required_name in \
  ML_DEPLOYMENT_ID \
  ML_OCI_REPOSITORY \
  ML_OCI_DIGEST \
  ML_RUN_SPEC_URI \
  ML_RUN_SPEC_SHA256 \
  ML_RUN_SPEC_OBJECT_VERSION \
  ML_DATA_URI \
  ML_RESULTS_URI \
  ML_CLOUD_PROVIDER \
  ML_MAX_RUNTIME_MINUTES \
  ML_CONTAINER_RUNTIME_PATH \
  ML_RECEIPT_OUTPUT_DIRECTORY
do
  require_environment "$required_name"
done

[[ "$ML_DEPLOYMENT_ID" =~ ^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$ ]] ||
  fail "ML_DEPLOYMENT_ID must be 3-48 lower-case letters, digits, or internal hyphens"

[[ "$ML_OCI_REPOSITORY" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)+$ ]] ||
  fail "ML_OCI_REPOSITORY is not a conservative lower-case OCI repository"
[[ "$ML_OCI_REPOSITORY" != *'..'* && "$ML_OCI_REPOSITORY" != *'//'* ]] ||
  fail "ML_OCI_REPOSITORY contains an empty or ambiguous component"
[[ "$ML_OCI_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail "ML_OCI_DIGEST must be a lower-case sha256 digest"

validate_uri ML_RUN_SPEC_URI
validate_uri ML_DATA_URI
validate_uri ML_RESULTS_URI

[[ "$ML_RUN_SPEC_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "ML_RUN_SPEC_SHA256 must be a lower-case SHA-256"
[[ "$ML_RUN_SPEC_OBJECT_VERSION" =~ ^[^[:space:]]{1,512}$ ]] ||
  fail "ML_RUN_SPEC_OBJECT_VERSION must be a non-empty provider object version"
has_control_character "$ML_RUN_SPEC_OBJECT_VERSION" &&
  fail "ML_RUN_SPEC_OBJECT_VERSION contains a control character"

case "$ML_CLOUD_PROVIDER" in
  aws)
    [[ "$ML_OCI_REPOSITORY" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/ ]] ||
      fail "AWS runners require a provider-local ECR repository"
    [[ "$ML_RUN_SPEC_URI" == s3://* && "$ML_DATA_URI" == s3://* && "$ML_RESULTS_URI" == s3://* ]] ||
      fail "AWS runners require provider-local s3 URIs"
    ;;
  gcp)
    [[ "$ML_OCI_REPOSITORY" =~ ^[a-z0-9-]+-docker\.pkg\.dev/ ]] ||
      fail "GCP runners require a provider-local Artifact Registry repository"
    [[ "$ML_RUN_SPEC_URI" == gs://* && "$ML_DATA_URI" == gs://* && "$ML_RESULTS_URI" == gs://* ]] ||
      fail "GCP runners require provider-local gs URIs"
    ;;
  azure)
    [[ "$ML_OCI_REPOSITORY" =~ ^[a-z0-9]{5,50}\.azurecr\.io/ ]] ||
      fail "Azure runners require a provider-local ACR repository"
    [[ "$ML_RUN_SPEC_URI" =~ ^https://[a-z0-9]{3,24}\.blob\.core\.windows\.net/ ]] ||
      fail "Azure runners require a provider-local Blob run-spec URI"
    [[ "$ML_DATA_URI" =~ ^https://[a-z0-9]{3,24}\.blob\.core\.windows\.net/ ]] ||
      fail "Azure runners require a provider-local Blob data URI"
    [[ "$ML_RESULTS_URI" =~ ^https://[a-z0-9]{3,24}\.blob\.core\.windows\.net/ ]] ||
      fail "Azure runners require a provider-local Blob results URI"
    ;;
  *) fail "ML_CLOUD_PROVIDER must be aws, gcp, or azure" ;;
esac

[[ "$ML_RUN_SPEC_URI" == *"/run-specs/${ML_DEPLOYMENT_ID}/${ML_RUN_SPEC_SHA256}.json" ]] ||
  fail "ML_RUN_SPEC_URI must end with the content-addressed run-spec path"
[[ "$ML_DATA_URI" == */ ]] ||
  fail "ML_DATA_URI must be a provider-local prefix ending in a slash"
[[ "$ML_RESULTS_URI" == *"/runs/${ML_DEPLOYMENT_ID}/results/" ]] ||
  fail "ML_RESULTS_URI must be the deployment-specific workload results prefix"

[[ "$ML_MAX_RUNTIME_MINUTES" =~ ^[0-9]+$ ]] ||
  fail "ML_MAX_RUNTIME_MINUTES must be an integer"
(( 10#$ML_MAX_RUNTIME_MINUTES >= 15 && 10#$ML_MAX_RUNTIME_MINUTES <= 720 )) ||
  fail "ML_MAX_RUNTIME_MINUTES must be between 15 and 720"

[[ "$ML_CONTAINER_RUNTIME_PATH" == /* ]] ||
  fail "ML_CONTAINER_RUNTIME_PATH must be absolute"
[[ "${ML_CONTAINER_RUNTIME_PATH##*/}" == "docker" || "${ML_CONTAINER_RUNTIME_PATH##*/}" == "podman" ]] ||
  fail "ML_CONTAINER_RUNTIME_PATH must name docker or podman"
[[ -f "$ML_CONTAINER_RUNTIME_PATH" && -x "$ML_CONTAINER_RUNTIME_PATH" ]] ||
  fail "ML_CONTAINER_RUNTIME_PATH is not an executable file"

[[ "$ML_RECEIPT_OUTPUT_DIRECTORY" == /* ]] ||
  fail "ML_RECEIPT_OUTPUT_DIRECTORY must be absolute"
has_control_character "$ML_RECEIPT_OUTPUT_DIRECTORY" &&
  fail "ML_RECEIPT_OUTPUT_DIRECTORY contains a control character"
[[ -d "$ML_RECEIPT_OUTPUT_DIRECTORY" && -w "$ML_RECEIPT_OUTPUT_DIRECTORY" ]] ||
  fail "ML_RECEIPT_OUTPUT_DIRECTORY must be an existing writable directory"
[[ ! -L "$ML_RECEIPT_OUTPUT_DIRECTORY" ]] ||
  fail "ML_RECEIPT_OUTPUT_DIRECTORY may not be a symbolic link"

readonly RECEIPT_PATH="${ML_RECEIPT_OUTPUT_DIRECTORY}/${RECEIPT_FILENAME}"
[[ ! -e "$RECEIPT_PATH" && ! -L "$RECEIPT_PATH" ]] ||
  fail "completion receipt already exists"

TIMEOUT_PATH=""
for timeout_candidate in /usr/bin/timeout /bin/timeout; do
  if [[ -f "$timeout_candidate" && -x "$timeout_candidate" ]]; then
    TIMEOUT_PATH="$timeout_candidate"
    break
  fi
done
readonly TIMEOUT_PATH
[[ -n "$TIMEOUT_PATH" ]] ||
  fail "GNU timeout is required"

readonly BOOTSTRAP_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEADLINE_MARKER_HELPER="${BOOTSTRAP_DIRECTORY}/deadline-marker.sh"
[[ -f "$DEADLINE_MARKER_HELPER" && -x "$DEADLINE_MARKER_HELPER" ]] ||
  fail "the static deadline marker helper is missing or not executable"

readonly DEADLINE_MARKER_PATH="${ML_RECEIPT_OUTPUT_DIRECTORY}/.execution-deadline-triggered.$$"
[[ ! -e "$DEADLINE_MARKER_PATH" && ! -L "$DEADLINE_MARKER_PATH" ]] ||
  fail "deadline marker already exists"

RECEIPT_TEMPORARY_PATH=""
cleanup_temporary_receipt() {
  if [[ -n "$RECEIPT_TEMPORARY_PATH" && -e "$RECEIPT_TEMPORARY_PATH" ]]; then
    rm -- "$RECEIPT_TEMPORARY_PATH"
  fi
  if [[ -e "$DEADLINE_MARKER_PATH" ]]; then
    rm -- "$DEADLINE_MARKER_PATH"
  fi
}
trap cleanup_temporary_receipt EXIT

readonly STARTED_AT_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
readonly OCI_IMAGE="${ML_OCI_REPOSITORY}@${ML_OCI_DIGEST}"
readonly CONTAINER_NAME="ml-${ML_DEPLOYMENT_ID}"
readonly TIMEOUT_SECONDS="$((10#$ML_MAX_RUNTIME_MINUTES * 60))s"

set +e
"$TIMEOUT_PATH" \
  --signal=TERM \
  --kill-after=60s \
  "$TIMEOUT_SECONDS" \
  "$DEADLINE_MARKER_HELPER" \
  "$DEADLINE_MARKER_PATH" \
  -- \
  "$ML_CONTAINER_RUNTIME_PATH" run \
  --rm \
  --pull=always \
  --name "$CONTAINER_NAME" \
  --env "ML_DEPLOYMENT_ID=${ML_DEPLOYMENT_ID}" \
  --env "ML_RUN_SPEC_URI=${ML_RUN_SPEC_URI}" \
  --env "ML_RUN_SPEC_SHA256=${ML_RUN_SPEC_SHA256}" \
  --env "ML_RUN_SPEC_OBJECT_VERSION=${ML_RUN_SPEC_OBJECT_VERSION}" \
  --env "ML_DATA_URI=${ML_DATA_URI}" \
  --env "ML_RESULTS_URI=${ML_RESULTS_URI}" \
  --env "ML_CLOUD_PROVIDER=${ML_CLOUD_PROVIDER}" \
  --env "ML_MAX_RUNTIME_MINUTES=${ML_MAX_RUNTIME_MINUTES}" \
  --env "ML_OCI_DIGEST=${ML_OCI_DIGEST}" \
  "$OCI_IMAGE"
runtime_exit_code=$?
set -e

if [[ -e "$DEADLINE_MARKER_PATH" ]]; then
  terminal_status="timed_out"
  container_exit_code=124
  guest_exit_code=124
else
  container_exit_code="$runtime_exit_code"
  guest_exit_code="$runtime_exit_code"
  if ((container_exit_code == 0)); then
    terminal_status="succeeded"
  else
    terminal_status="failed"
  fi
fi

finished_at_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
emit_receipt "$terminal_status" "$container_exit_code" "$finished_at_utc" ||
  fail "could not atomically publish completion receipt" 74

exit "$guest_exit_code"
