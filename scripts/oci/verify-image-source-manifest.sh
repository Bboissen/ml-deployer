#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIRECTORY}/../.." && pwd -P)"
readonly SOURCE_ROOT="${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke"
readonly MANIFEST_PATH="${SOURCE_ROOT}/image-source-manifest.json"

fail() {
  printf 'verify-image-source-manifest: ERROR: %s\n' "$1" >&2
  exit 2
}

[[ -f "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" ]] || fail "image source manifest is missing"
jq -e '
  (keys == ["files", "schema_version"])
  and .schema_version == "1.0.0"
  and (.files | type == "array" and length == 8)
  and ([.files[].path] == ([.files[].path] | sort))
  and ([.files[].path] | unique | length) == 8
  and all(.files[];
    (keys == ["bytes", "path", "sha256"])
    and (.bytes | type == "number" and . > 0 and . == floor)
    and ((.path == ".dockerignore") or (.path | test("^[A-Za-z0-9][A-Za-z0-9._/-]*$")))
    and (.sha256 | test("^[0-9a-f]{64}$")))
' "$MANIFEST_PATH" >/dev/null || fail "image source manifest shape is invalid"

while IFS=$'\t' read -r relative_path expected_bytes expected_sha256; do
  source_path="${SOURCE_ROOT}/${relative_path}"
  [[ -f "$source_path" && ! -L "$source_path" ]] || fail "source is missing: ${relative_path}"
  [[ "$(wc -c <"$source_path")" == "$expected_bytes" ]] || fail "source size changed: ${relative_path}"
  [[ "$(sha256sum "$source_path" | cut -d' ' -f1)" == "$expected_sha256" ]] ||
    fail "source checksum changed: ${relative_path}"
done < <(jq -r '.files[] | [.path, (.bytes | tostring), .sha256] | @tsv' "$MANIFEST_PATH")

printf 'Image source manifest verified: %s\n' "$(sha256sum "$MANIFEST_PATH" | cut -d' ' -f1)"
