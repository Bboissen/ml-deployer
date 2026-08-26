#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s INDEX.json\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq is required to validate deployment-index entries.\n' >&2
  exit 3
fi

index_path=$1
if [[ ! -f "$index_path" ]]; then
  printf 'ERROR: deployment-index entry is not a regular file: %s\n' "$index_path" >&2
  exit 2
fi

if ! jq -e '
  . as $index
  | type == "object"
    and ((keys | sort) == ([
      "account_scope",
      "backend_key",
      "deployment_id",
      "lifecycle_status",
      "platform_contract_sha256",
      "provider",
      "region",
      "request_sha256",
      "schema_version"
    ] | sort))
    and ($index.schema_version == "1.0.0")
    and (["aws", "gcp", "azure"] | index($index.provider) != null)
    and (($index.account_scope | type) == "string")
    and ($index.account_scope | test("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$"))
    and (($index.region | type) == "string")
    and ($index.region | test("^[a-z0-9][a-z0-9-]{1,63}$"))
    and (($index.deployment_id | type) == "string")
    and ($index.deployment_id | test("^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$"))
    and ($index.backend_key == (
      $index.provider + "/" + $index.account_scope + "/" + $index.region
      + "/runner/" + $index.deployment_id + ".tfstate"
    ))
    and ($index.request_sha256 | test("^[0-9a-f]{64}$"))
    and ($index.platform_contract_sha256 | test("^[0-9a-f]{64}$"))
    and (["planned", "applied", "deadline_terminated", "destroyed", "reconciled"]
      | index($index.lifecycle_status) != null)
' "$index_path" >/dev/null; then
  printf 'ERROR: deployment-index entry violates the frozen Goal 02 contract: %s\n' "$index_path" >&2
  exit 2
fi

jq -cS . "$index_path"
