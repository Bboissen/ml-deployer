#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: %s RESULT_MANIFEST.json\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required to validate result manifests.\n' >&2
  exit 3
}

readonly MANIFEST_PATH="$1"
[[ -f "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" ]] || {
  printf 'ERROR: result manifest is not a regular non-symlink file: %s\n' "$MANIFEST_PATH" >&2
  exit 2
}

if ! jq -e '
  . as $manifest
  | type == "object"
    and ((keys | sort) == (["artifacts", "run_spec_sha256", "schema_version", "workload"] | sort))
    and ($manifest.schema_version == "1.0.0")
    and (($manifest.workload | type) == "string")
    and ($manifest.workload | test("^[a-z0-9](?:[a-z0-9-]{1,62}[a-z0-9])$"))
    and (($manifest.run_spec_sha256 | type) == "string")
    and ($manifest.run_spec_sha256 | test("^[0-9a-f]{64}$"))
    and (($manifest.artifacts | type) == "array")
    and (($manifest.artifacts | length) >= 1 and ($manifest.artifacts | length) <= 64)
    and ([$manifest.artifacts[].path] as $paths
      | $paths == ($paths | sort)
      and (($paths | unique | length) == ($paths | length)))
    and ([$manifest.artifacts[].bytes] | add <= 1073741824)
    and (all($manifest.artifacts[];
      type == "object"
      and ((keys | sort) == (["bytes", "content_type", "path", "sha256"] | sort))
      and ((.path | type) == "string")
      and (.path | test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$"))
      and (.path != "result-manifest.json")
      and ((.path | split("/") | all(. != "" and . != "." and . != "..")))
      and ((.content_type | type) == "string")
      and (.content_type | test("^[A-Za-z0-9][A-Za-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+-]*$"))
      and ((.bytes | type) == "number")
      and (.bytes == (.bytes | floor))
      and (.bytes >= 1 and .bytes <= 1073741824)
      and ((.sha256 | type) == "string")
      and (.sha256 | test("^[0-9a-f]{64}$"))
    ))
' "$MANIFEST_PATH" >/dev/null; then
  printf 'ERROR: result manifest violates the canonical contract: %s\n' "$MANIFEST_PATH" >&2
  exit 2
fi

jq -cS . "$MANIFEST_PATH"
