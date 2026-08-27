#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${TEST_DIRECTORY}/../.." && pwd -P)"
readonly GUEST_RUNNER="${REPOSITORY_ROOT}/shared/bootstrap/guest-runner.sh"
readonly DEADLINE_MARKER_HELPER="${REPOSITORY_ROOT}/shared/bootstrap/deadline-marker.sh"

fail() {
  printf 'test-guest-runner: FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "${context}: expected ${expected}, got ${actual}"
}

assert_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$path" ||
    fail "${path} does not contain: ${expected}"
}

readonly TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'find "$TEMPORARY_DIRECTORY" -depth -delete' EXIT

readonly FAKE_RUNTIME="${TEST_DIRECTORY}/fixtures/docker"
readonly FAKE_COUNT="${TEMPORARY_DIRECTORY}/runtime-count"
readonly FAKE_ARGUMENTS="${TEMPORARY_DIRECTORY}/runtime-arguments"

jq -e '
  .additionalProperties == false
  and (.properties.oci_repository.pattern | length) > 0
  and (.properties.run_spec_uri.pattern | contains("run-specs"))
  and (.properties.results_uri.pattern | contains("results"))
  and (.properties.run_spec_object_version.pattern | contains("\\u0000"))
' "${REPOSITORY_ROOT}/shared/contracts/local-execution-receipt.schema.json" >/dev/null \
  || fail "local receipt schema lost a provider/path/control-character constraint"

readonly DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
readonly RUN_SPEC_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly AWS_REPOSITORY="123456789012.dkr.ecr.us-east-1.amazonaws.com/ml-runner"
readonly RUN_SPEC_URI="s3://example-run-specs/run-specs/smoke-001/${RUN_SPEC_SHA256}.json"

run_guest() {
  local receipt_directory="$1"
  local runtime_exit_code="$2"
  shift 2

  env \
    ML_DEPLOYMENT_ID="smoke-001" \
    ML_OCI_REPOSITORY="$AWS_REPOSITORY" \
    ML_OCI_DIGEST="$DIGEST" \
    ML_RUN_SPEC_URI="$RUN_SPEC_URI" \
    ML_RUN_SPEC_SHA256="$RUN_SPEC_SHA256" \
    ML_RUN_SPEC_OBJECT_VERSION="example-version-001" \
    ML_DATA_URI="s3://example-data/" \
    ML_RESULTS_URI="s3://example-results/runs/smoke-001/results/" \
    ML_CLOUD_PROVIDER="aws" \
    ML_MAX_RUNTIME_MINUTES="15" \
    ML_CONTAINER_RUNTIME_PATH="$FAKE_RUNTIME" \
    ML_RECEIPT_OUTPUT_DIRECTORY="$receipt_directory" \
    FAKE_RUNTIME_COUNT="$FAKE_COUNT" \
    FAKE_RUNTIME_ARGUMENTS="$FAKE_ARGUMENTS" \
    FAKE_RUNTIME_EXIT_CODE="$runtime_exit_code" \
    "$@" \
    "$GUEST_RUNNER"
}

success_receipts="${TEMPORARY_DIRECTORY}/success-receipts"
mkdir "$success_receipts"
run_guest "$success_receipts" 0

success_receipt="${success_receipts}/execution-receipt.local.json"
[[ -f "$success_receipt" ]] || fail "success receipt was not created"
assert_equals "1" "$(wc -l <"$FAKE_COUNT" | tr -d ' ')" "runtime invocation count"
assert_contains "$FAKE_ARGUMENTS" "run"
assert_contains "$FAKE_ARGUMENTS" "--pull=always"
assert_contains "$FAKE_ARGUMENTS" "${AWS_REPOSITORY}@${DIGEST}"
assert_contains "$FAKE_ARGUMENTS" "ML_DEPLOYMENT_ID=smoke-001"
assert_contains "$FAKE_ARGUMENTS" "ML_RUN_SPEC_URI=${RUN_SPEC_URI}"
assert_contains "$FAKE_ARGUMENTS" "ML_RUN_SPEC_SHA256=${RUN_SPEC_SHA256}"
assert_contains "$success_receipt" '"schema_version": "1.0.0"'
assert_contains "$success_receipt" '"receipt_kind": "local_execution"'
assert_contains "$success_receipt" '"execution_terminal": true'
assert_contains "$success_receipt" '"status": "succeeded"'
assert_contains "$success_receipt" '"container_exit_code": 0'
jq -e --arg digest "$DIGEST" --arg run_spec_sha256 "$RUN_SPEC_SHA256" '
  (keys | sort) == ([
    "container_exit_code",
    "data_uri",
    "deployment_id",
    "execution_terminal",
    "finished_at_utc",
    "maximum_runtime_minutes",
    "oci_digest",
    "oci_repository",
    "provider",
    "receipt_kind",
    "results_uri",
    "run_spec_object_version",
    "run_spec_sha256",
    "run_spec_uri",
    "schema_version",
    "started_at_utc",
    "status"
  ] | sort)
  and .schema_version == "1.0.0"
  and .receipt_kind == "local_execution"
  and .execution_terminal == true
  and .oci_digest == $digest
  and .run_spec_sha256 == $run_spec_sha256
  and .status == "succeeded"
  and .container_exit_code == 0
' "$success_receipt" >/dev/null || fail "local execution receipt violates its closed contract"
assert_equals "600" "$(stat -c '%a' "$success_receipt")" "receipt mode"
if find "$success_receipts" -maxdepth 1 -name '.execution-receipt.*.tmp' -print -quit | grep -q .; then
  fail "temporary receipt was left behind"
fi

set +e
run_guest "$success_receipts" 0 >/dev/null 2>&1
duplicate_exit_code=$?
set -e
assert_equals "64" "$duplicate_exit_code" "duplicate receipt exit code"
assert_equals "1" "$(wc -l <"$FAKE_COUNT" | tr -d ' ')" "duplicate receipt runtime count"

gcp_receipts="${TEMPORARY_DIRECTORY}/gcp-receipts"
mkdir "$gcp_receipts"
run_guest "$gcp_receipts" 0 \
  ML_CLOUD_PROVIDER="gcp" \
  ML_OCI_REPOSITORY="europe-west1-docker.pkg.dev/example-project/ml/ml-runner" \
  ML_RUN_SPEC_URI="gs://example-run-specs/run-specs/smoke-001/${RUN_SPEC_SHA256}.json" \
  ML_RUN_SPEC_OBJECT_VERSION="1724630400000000" \
  ML_DATA_URI="gs://example-data/" \
  ML_RESULTS_URI="gs://example-results/runs/smoke-001/results/"
assert_contains "${gcp_receipts}/execution-receipt.local.json" '"provider": "gcp"'
assert_contains "${gcp_receipts}/execution-receipt.local.json" '"status": "succeeded"'

azure_receipts="${TEMPORARY_DIRECTORY}/azure-receipts"
mkdir "$azure_receipts"
run_guest "$azure_receipts" 0 \
  ML_CLOUD_PROVIDER="azure" \
  ML_WORKLOAD_IDENTITY_CLIENT_ID="44444444-4444-4444-4444-444444444444" \
  ML_OCI_REPOSITORY="exampleml.azurecr.io/ml-runner" \
  ML_RUN_SPEC_URI="https://examplemlresults.blob.core.windows.net/results/run-specs/smoke-001/${RUN_SPEC_SHA256}.json" \
  ML_RUN_SPEC_OBJECT_VERSION="2026-08-26T00:00:00.0000000Z" \
  ML_DATA_URI="https://examplemldata.blob.core.windows.net/data/" \
  ML_RESULTS_URI="https://examplemlresults.blob.core.windows.net/results/runs/smoke-001/results/"
assert_contains "${azure_receipts}/execution-receipt.local.json" '"provider": "azure"'
assert_contains "${azure_receipts}/execution-receipt.local.json" '"status": "succeeded"'
assert_contains "$FAKE_ARGUMENTS" "ML_WORKLOAD_IDENTITY_CLIENT_ID=44444444-4444-4444-4444-444444444444"

failure_receipts="${TEMPORARY_DIRECTORY}/failure-receipts"
mkdir "$failure_receipts"
set +e
run_guest "$failure_receipts" 23 >/dev/null 2>&1
failure_exit_code=$?
set -e
assert_equals "23" "$failure_exit_code" "failed container exit code"
assert_contains "${failure_receipts}/execution-receipt.local.json" '"status": "failed"'
assert_contains "${failure_receipts}/execution-receipt.local.json" '"container_exit_code": 23'

exit_124_receipts="${TEMPORARY_DIRECTORY}/exit-124-receipts"
mkdir "$exit_124_receipts"
set +e
run_guest "$exit_124_receipts" 124 >/dev/null 2>&1
exit_124_code=$?
set -e
assert_equals "124" "$exit_124_code" "container exit-124 code"
assert_contains "${exit_124_receipts}/execution-receipt.local.json" '"status": "failed"'
assert_contains "${exit_124_receipts}/execution-receipt.local.json" '"container_exit_code": 124'

timeout_marker="${TEMPORARY_DIRECTORY}/deadline-triggered"
timeout_count="${TEMPORARY_DIRECTORY}/timeout-runtime-count"
timeout_arguments="${TEMPORARY_DIRECTORY}/timeout-runtime-arguments"
timeout_pid_file="${TEMPORARY_DIRECTORY}/timeout-runtime-pid"
set +e
{
  env \
    FAKE_RUNTIME_COUNT="$timeout_count" \
    FAKE_RUNTIME_ARGUMENTS="$timeout_arguments" \
    FAKE_RUNTIME_SLEEP_SECONDS="30" \
    FAKE_RUNTIME_IGNORE_TERM="1" \
    FAKE_RUNTIME_PID_FILE="$timeout_pid_file" \
    /usr/bin/timeout --signal=TERM --kill-after=1s 1s \
    "$DEADLINE_MARKER_HELPER" "$timeout_marker" -- "$FAKE_RUNTIME" run >/dev/null 2>&1
  real_timeout_exit_code=$?
} 2>/dev/null
set -e
assert_equals "137" "$real_timeout_exit_code" "real GNU kill-after escalation exit code"
[[ -f "$timeout_marker" ]] || fail "real timeout did not create its deadline marker"
assert_equals "1" "$(wc -l <"$timeout_count" | tr -d ' ')" "real timeout invocation count"
[[ -f "$timeout_pid_file" ]] || fail "real timeout did not record its child PID"
if kill -0 "$(cat "$timeout_pid_file")" 2>/dev/null; then
  fail "real timeout left its signal-resistant child running"
fi

assert_rejected_without_runtime() {
  local context="$1"
  shift
  local receipt_directory="${TEMPORARY_DIRECTORY}/rejected-${context}"
  local before_count after_count exit_code
  mkdir "$receipt_directory"
  before_count="$(wc -l <"$FAKE_COUNT" | tr -d ' ')"

  set +e
  run_guest "$receipt_directory" 0 "$@" >/dev/null 2>&1
  exit_code=$?
  set -e

  [[ "$exit_code" != 0 ]] || fail "${context} was unexpectedly accepted"
  after_count="$(wc -l <"$FAKE_COUNT" | tr -d ' ')"
  assert_equals "$before_count" "$after_count" "${context} runtime count"
  [[ ! -e "${receipt_directory}/execution-receipt.local.json" ]] ||
    fail "${context} unexpectedly emitted a receipt"
}

assert_rejected_without_runtime mutable-tag \
  ML_OCI_REPOSITORY="${AWS_REPOSITORY}:latest"
assert_rejected_without_runtime invalid-digest \
  ML_OCI_DIGEST="sha256:not-a-digest"
assert_rejected_without_runtime short-runtime \
  ML_MAX_RUNTIME_MINUTES="14"
assert_rejected_without_runtime long-runtime \
  ML_MAX_RUNTIME_MINUTES="721"
assert_rejected_without_runtime nonnumeric-runtime \
  ML_MAX_RUNTIME_MINUTES="15m"
assert_rejected_without_runtime invalid-provider \
  ML_CLOUD_PROVIDER="digitalocean"
assert_rejected_without_runtime wrong-provider-binding \
  ML_CLOUD_PROVIDER="gcp"
assert_rejected_without_runtime azure-identity-on-aws \
  ML_WORKLOAD_IDENTITY_CLIENT_ID="44444444-4444-4444-4444-444444444444"
assert_rejected_without_runtime credential-query \
  ML_RUN_SPEC_URI="${RUN_SPEC_URI}?sig=secret"
assert_rejected_without_runtime arbitrary-runtime \
  ML_CONTAINER_RUNTIME_PATH="/bin/sh"
assert_rejected_without_runtime object-version-control-character \
  ML_RUN_SPEC_OBJECT_VERSION=$'invalid\001version'
assert_rejected_without_runtime wrong-results-prefix \
  ML_RESULTS_URI="s3://example-results/runs/smoke-001/"

positional_receipts="${TEMPORARY_DIRECTORY}/positional-receipts"
mkdir "$positional_receipts"
set +e
env \
  ML_DEPLOYMENT_ID="smoke-001" \
  ML_OCI_REPOSITORY="$AWS_REPOSITORY" \
  ML_OCI_DIGEST="$DIGEST" \
  ML_RUN_SPEC_URI="$RUN_SPEC_URI" \
  ML_RUN_SPEC_SHA256="$RUN_SPEC_SHA256" \
  ML_RUN_SPEC_OBJECT_VERSION="example-version-001" \
  ML_DATA_URI="s3://example-data/" \
  ML_RESULTS_URI="s3://example-results/runs/smoke-001/results/" \
  ML_CLOUD_PROVIDER="aws" \
  ML_MAX_RUNTIME_MINUTES="15" \
  ML_CONTAINER_RUNTIME_PATH="$FAKE_RUNTIME" \
  ML_RECEIPT_OUTPUT_DIRECTORY="$positional_receipts" \
  "$GUEST_RUNNER" 'echo unsafe' >/dev/null 2>&1
positional_exit_code=$?
set -e
assert_equals "64" "$positional_exit_code" "positional argument exit code"

printf 'test-guest-runner: PASS\n'
