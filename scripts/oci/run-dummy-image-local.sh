#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIRECTORY}/../.." && pwd -P)"
readonly WORKLOAD_ROOT="${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke"
readonly IMAGE_TAG="${1:-demo/tool-complete-dummy:review}"

fail() {
  printf 'run-dummy-image-local: ERROR: %s\n' "$1" >&2
  exit 2
}

(( $# <= 1 )) || fail "usage: $0 [local-image-tag]"
[[ "$IMAGE_TAG" =~ ^[a-z0-9][a-z0-9./_-]*:[a-z0-9][a-z0-9._-]*$ ]] ||
  fail "local image tag is not conservative"
command -v docker >/dev/null 2>&1 || fail "docker is required"
docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 ||
  fail "local image is missing; run make dummy-image-build first"

readonly DEPLOYMENT_ID="dummy-local"
readonly RUN_SPEC_SHA256="$(sha256sum "${WORKLOAD_ROOT}/run-spec.example.json" | cut -d' ' -f1)"
readonly INPUT_SHA256="$(jq -er '.sha256' "${WORKLOAD_ROOT}/fixture-contract.json")"
readonly INPUT_OBJECT_KEY="$(jq -er '.object_key' "${WORKLOAD_ROOT}/fixture-contract.json")"
readonly RUNTIME_PARENT="${REPOSITORY_ROOT}/.dummy-runtime"
mkdir -p "$RUNTIME_PARENT"
readonly RUNTIME_ROOT="$(mktemp -d "${RUNTIME_PARENT}/local.XXXXXX")"
readonly OBJECT_ROOT="${RUNTIME_ROOT}/object-store"
readonly RUN_SPEC_PATH="${OBJECT_ROOT}/s3/local-results/run-specs/${DEPLOYMENT_ID}/${RUN_SPEC_SHA256}.json"
readonly INPUT_PATH="${OBJECT_ROOT}/s3/local-data/${INPUT_OBJECT_KEY}"
readonly RESULT_PATH="${OBJECT_ROOT}/s3/local-results/runs/${DEPLOYMENT_ID}/results"
readonly SCRATCH_PATH="${RUNTIME_ROOT}/scratch"

install -D -m 0444 "${WORKLOAD_ROOT}/run-spec.example.json" "$RUN_SPEC_PATH"
install -D -m 0444 "${WORKLOAD_ROOT}/fixtures/synthetic-input.parquet" "$INPUT_PATH"
install -d -m 0777 "$RESULT_PATH" "$SCRATCH_PATH"

set +e
docker run \
  --rm \
  --platform linux/amd64 \
  --network none \
  --cpus 2 \
  --memory 7g \
  --shm-size 256m \
  --pids-limit 512 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,size=2g \
  --volume "${OBJECT_ROOT}:/work/object-store:rw" \
  --env "ML_DEPLOYMENT_ID=${DEPLOYMENT_ID}" \
  --env "ML_CLOUD_PROVIDER=aws" \
  --env "ML_RUN_SPEC_URI=s3://local-results/run-specs/${DEPLOYMENT_ID}/${RUN_SPEC_SHA256}.json" \
  --env "ML_RUN_SPEC_SHA256=${RUN_SPEC_SHA256}" \
  --env "ML_RUN_SPEC_OBJECT_VERSION=local-v1" \
  --env "ML_DATA_URI=s3://local-data/" \
  --env "ML_RESULTS_URI=s3://local-results/runs/${DEPLOYMENT_ID}/results/" \
  --env "ML_OCI_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" \
  --env "ML_MAX_RUNTIME_MINUTES=15" \
  --env "ML_LOCAL_OBJECT_ROOT=/work/object-store" \
  "$IMAGE_TAG"
container_exit_code=$?
set -e

(( container_exit_code == 0 )) ||
  fail "container failed with exit ${container_exit_code}; preserved runtime: ${RUNTIME_ROOT}"
[[ -f "${RESULT_PATH}/result-manifest.json" && ! -L "${RESULT_PATH}/result-manifest.json" ]] ||
  fail "result manifest is missing; preserved runtime: ${RUNTIME_ROOT}"

bash "${REPOSITORY_ROOT}/scripts/validate-result-manifest.sh" \
  "${RESULT_PATH}/result-manifest.json" >/dev/null

while IFS=$'\t' read -r relative_path expected_bytes expected_sha256; do
  artifact_path="${RESULT_PATH}/${relative_path}"
  [[ -f "$artifact_path" && ! -L "$artifact_path" ]] || fail "manifest artifact is missing: ${relative_path}"
  [[ "$(wc -c <"$artifact_path")" == "$expected_bytes" ]] || fail "artifact size mismatch: ${relative_path}"
  [[ "$(sha256sum "$artifact_path" | cut -d' ' -f1)" == "$expected_sha256" ]] ||
    fail "artifact checksum mismatch: ${relative_path}"
done < <(jq -r '.artifacts[] | [.path, (.bytes | tostring), .sha256] | @tsv' "${RESULT_PATH}/result-manifest.json")

mapfile -t expected_paths < <(jq -r '.required_artifacts[]' "${WORKLOAD_ROOT}/expected-output.json")
mapfile -t actual_paths < <(jq -r '.artifacts[].path' "${RESULT_PATH}/result-manifest.json")
[[ "${expected_paths[*]}" == "${actual_paths[*]}" ]] || fail "manifest paths differ from expected-output policy"

readonly MANIFEST_SHA256="$(sha256sum "${RESULT_PATH}/result-manifest.json" | cut -d' ' -f1)"
jq -cn \
  --arg runtime_root "$RUNTIME_ROOT" \
  --arg run_spec_sha256 "$RUN_SPEC_SHA256" \
  --arg input_sha256 "$INPUT_SHA256" \
  --arg result_manifest_sha256 "$MANIFEST_SHA256" \
  '{
    schema_version: "1.0.0",
    operation: "local_dummy_run",
    cloud_action: false,
    container_exit_code: 0,
    runtime_root: $runtime_root,
    run_spec_sha256: $run_spec_sha256,
    input_sha256: $input_sha256,
    result_manifest_sha256: $result_manifest_sha256,
    result_manifest_created_last: true
  }'
