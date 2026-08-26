#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s REQUEST.json\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq is required to validate runner requests.\n' >&2
  exit 3
fi

request_path=$1
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profiles_path="$repo_root/shared/contracts/resource-profiles.json"

if [[ ! -f "$request_path" ]]; then
  printf 'ERROR: runner request is not a regular file: %s\n' "$request_path" >&2
  exit 2
fi

if ! jq -e --slurpfile profiles "$profiles_path" '
  . as $request
  | type == "object"
    and ((keys | sort) == ([
      "capacity_mode",
      "deployment_id",
      "maximum_runtime_minutes",
      "oci_digest",
      "oci_repository",
      "provider",
      "resource_profile",
      "run_spec_object_version",
      "run_spec_sha256",
      "run_spec_uri",
      "schema_version"
    ] | sort))
    and ($request.schema_version == "1.0.0")
    and (($request.deployment_id | type) == "string")
    and ($request.deployment_id | test("^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$"))
    and (["aws", "gcp", "azure"] | index($request.provider) != null)
    and (($request.oci_repository | type) == "string")
    and (($request.oci_repository | length) >= 3 and ($request.oci_repository | length) <= 255)
    and (($request.oci_repository | contains("@") or contains(":")) | not)
    and (($request.oci_digest | type) == "string")
    and ($request.oci_digest | test("^sha256:[0-9a-f]{64}$"))
    and (($request.run_spec_uri | type) == "string")
    and (($request.run_spec_uri | length) >= 8 and ($request.run_spec_uri | length) <= 2048)
    and (($request.run_spec_uri | test("[?#[:space:]]")) | not)
    and (($request.run_spec_sha256 | type) == "string")
    and ($request.run_spec_sha256 | test("^[0-9a-f]{64}$"))
    and (($request.run_spec_object_version | type) == "string")
    and ($request.run_spec_object_version | test("^[^[:cntrl:][:space:]]{1,512}$"))
    and ($profiles[0].profiles | has($request.resource_profile))
    and ($request.capacity_mode == "standard")
    and (($request.maximum_runtime_minutes | type) == "number")
    and ($request.maximum_runtime_minutes == ($request.maximum_runtime_minutes | floor))
    and ($request.maximum_runtime_minutes >= $profiles[0].maximum_runtime_minutes.minimum)
    and ($request.maximum_runtime_minutes <= $profiles[0].maximum_runtime_minutes.maximum)
    and ($request.run_spec_uri | endswith(
      "/run-specs/" + $request.deployment_id + "/" + $request.run_spec_sha256 + ".json"
    ))
    and (
      if $request.provider == "aws" then
        ($request.oci_repository | test("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+$"))
        and ($request.run_spec_uri | test("^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/[^?#\\s]+$"))
      elif $request.provider == "gcp" then
        ($request.oci_repository | test("^[a-z0-9-]+-docker\\.pkg\\.dev/[a-z0-9-]+(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*){2,}$"))
        and ($request.run_spec_uri | test("^gs://[a-z0-9][a-z0-9._-]{1,220}/[^?#\\s]+$"))
      else
        ($request.oci_repository | test("^[a-z0-9]{5,50}\\.azurecr\\.io(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+$"))
        and ($request.run_spec_uri | test("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?/[^?#\\s]+$"))
      end
    )
' "$request_path" >/dev/null; then
  printf 'ERROR: runner request violates the frozen Goal 02 contract: %s\n' "$request_path" >&2
  exit 2
fi

jq -cS . "$request_path"
