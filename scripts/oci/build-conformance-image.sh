#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIRECTORY}/../.." && pwd -P)"
readonly BUILD_CONTEXT="${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke"
readonly IMAGE_TAG="${1:-demo/tool-complete-dummy:review}"

fail() {
  printf 'build-conformance-image: ERROR: %s\n' "$1" >&2
  exit 2
}

(( $# <= 1 )) || fail "usage: $0 [local-image-tag]"
[[ "$IMAGE_TAG" =~ ^[a-z0-9][a-z0-9./_-]*:[a-z0-9][a-z0-9._-]*$ ]] || fail "local image tag is not conservative"
command -v docker >/dev/null 2>&1 || fail "docker is required"
docker buildx version >/dev/null 2>&1 || fail "docker buildx is required"

"${SCRIPT_DIRECTORY}/verify-image-source-manifest.sh" >/dev/null
source_manifest="$(sha256sum "${BUILD_CONTEXT}/image-source-manifest.json" | cut -d' ' -f1)"

runtime_directory="${REPOSITORY_ROOT}/.dummy-runtime/build"
mkdir -p "$runtime_directory"
metadata_path="$(mktemp "${runtime_directory}/metadata.XXXXXX.json")"
trap 'rm -f -- "$metadata_path"' EXIT

docker buildx build \
  --platform linux/amd64 \
  --load \
  --provenance=false \
  --build-arg "OCI_SOURCE_REVISION=${source_manifest}" \
  --metadata-file "$metadata_path" \
  --tag "$IMAGE_TAG" \
  "$BUILD_CONTEXT"

image_digest="$(jq -er '.["containerimage.digest"] | select(test("^sha256:[0-9a-f]{64}$"))' "$metadata_path")" ||
  fail "BuildKit did not return a canonical image digest"

jq -cn \
  --arg image_tag "$IMAGE_TAG" \
  --arg image_digest "$image_digest" \
  --arg source_manifest_sha256 "$source_manifest" \
  '{
    schema_version: "1.0.0",
    operation: "local_build_only",
    platform: "linux/amd64",
    image_tag: $image_tag,
    local_image_digest: $image_digest,
    source_manifest_sha256: $source_manifest_sha256,
    cloud_mutation: false,
    workload_executed: false
  }'
