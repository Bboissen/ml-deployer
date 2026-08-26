#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s COMMAND-RESULT.json\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq is required to validate command results.\n' >&2
  exit 3
fi

result_path=$1
if [[ ! -f "$result_path" ]]; then
  printf 'ERROR: command result is not a regular file: %s\n' "$result_path" >&2
  exit 2
fi

if ! jq -e '
  . as $result
  | type == "object"
    and ((keys | sort) == ([
      "artifacts",
      "checks",
      "command",
      "deployment_id",
      "errors",
      "exit_code",
      "generated_at_utc",
      "provider",
      "schema_version",
      "scope",
      "status",
      "warnings"
    ] | sort))
    and ($result.schema_version == "1.0.0")
    and (["doctor", "plan", "observe", "destroy"] | index($result.command) != null)
    and (["aws", "gcp", "azure"] | index($result.provider) != null)
    and (["pass", "fail", "blocked"] | index($result.status) != null)
    and (($result.exit_code | type) == "number")
    and ($result.exit_code == ($result.exit_code | floor))
    and ($result.exit_code >= 0 and $result.exit_code <= 9)
    and (($result.generated_at_utc | type) == "string")
    and (try ($result.generated_at_utc | fromdateiso8601) catch false) != false
    and (
      ($result.deployment_id == null)
      or (
        ($result.deployment_id | type) == "string"
        and ($result.deployment_id | test("^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$"))
      )
    )
    and (($result.scope | type) == "object")
    and (($result.scope | keys | sort) == (["account_id", "region", "root_kind"] | sort))
    and (
      ($result.scope.account_id == null)
      or (
        ($result.scope.account_id | type) == "string"
        and ($result.scope.account_id | test("^[^[:cntrl:]]{1,256}$"))
      )
    )
    and (
      ($result.scope.region == null)
      or (
        ($result.scope.region | type) == "string"
        and ($result.scope.region | test("^[^[:cntrl:]]{1,64}$"))
      )
    )
    and (["bootstrap", "platform", "runner", null] | index($result.scope.root_kind) != null)
    and (($result.checks | type) == "array")
    and (($result.checks | length) >= 1)
    and (all($result.checks[]; . as $check
      | ($check | type) == "object"
      and (($check | keys) - ["id", "status", "summary", "evidence"] | length == 0)
      and ($check | has("id") and has("status") and has("summary"))
      and ($check.id | type) == "string"
      and ($check.id | test("^[a-z][a-z0-9_.-]*$"))
      and (["pass", "fail", "blocked", "unknown"] | index($check.status) != null)
      and ($check.summary | type) == "string"
      and ($check.summary | test("^[^[:cntrl:]]{1,512}$"))
      and (
        ($check | has("evidence") | not)
        or (
          ($check.evidence | type) == "object"
          and (($check.evidence | keys) - ["reference", "sha256", "count"] | length == 0)
          and (($check.evidence | keys | length) >= 1 and ($check.evidence | keys | length) <= 3)
          and (
            ($check.evidence | has("reference") | not)
            or (
              ($check.evidence.reference | type) == "string"
              and ($check.evidence.reference | test("^[^[:cntrl:]]{1,512}$"))
              and (($check.evidence.reference | test(
                "access[_-]?token|secret|authorization|bearer|password|private[_-]?key|session[_-]?token|sas=|x-amz-signature";
                "i"
              )) | not)
            )
          )
          and (
            ($check.evidence | has("sha256") | not)
            or (
              ($check.evidence.sha256 | type) == "string"
              and ($check.evidence.sha256 | test("^[0-9a-f]{64}$"))
            )
          )
          and (
            ($check.evidence | has("count") | not)
            or (
              ($check.evidence.count | type) == "number"
              and ($check.evidence.count == ($check.evidence.count | floor))
              and ($check.evidence.count >= 0)
            )
          )
        )
      )
    ))
    and (($result.artifacts | type) == "array")
    and (all($result.artifacts[]; . as $artifact
      | ($artifact | type) == "object"
      and (($artifact | keys | sort) == (["bytes", "path", "sha256"] | sort))
      and ($artifact.path | type) == "string"
      and ($artifact.path | test("^[^[:cntrl:]]{1,1024}$"))
      and ($artifact.bytes | type) == "number"
      and ($artifact.bytes == ($artifact.bytes | floor))
      and ($artifact.bytes >= 0)
      and ($artifact.sha256 | type) == "string"
      and ($artifact.sha256 | test("^[0-9a-f]{64}$"))
    ))
    and (($result.warnings | type) == "array")
    and (all($result.warnings[]; type == "string" and test("^[^[:cntrl:]]{1,512}$")))
    and (($result.errors | type) == "array")
    and (all($result.errors[]; . as $error
      | ($error | type) == "object"
      and (($error | keys | sort) == (["code", "message"] | sort))
      and ($error.code | type) == "string"
      and ($error.code | test("^[A-Z][A-Z0-9_]*$"))
      and ($error.message | type) == "string"
      and ($error.message | test("^[^[:cntrl:]]{1,512}$"))
    ))
    and (
      if $result.status == "pass" then
        $result.exit_code == 0
        and $result.scope.account_id != null
        and $result.scope.region != null
        and ($result.errors | length) == 0
        and all($result.checks[]; .status == "pass")
      else
        $result.exit_code != 0
      end
    )
    and (
      if $result.command == "doctor" then
        $result.deployment_id == null and $result.scope.root_kind == null
      elif $result.command == "plan" then
        (["bootstrap", "platform", "runner"] | index($result.scope.root_kind) != null)
        and (
          if $result.scope.root_kind == "runner" then
            $result.deployment_id != null
          else
            $result.deployment_id == null
          end
        )
      else
        $result.deployment_id != null and $result.scope.root_kind == "runner"
      end
    )
' "$result_path" >/dev/null; then
  printf 'ERROR: command result violates the frozen Goal 02 contract: %s\n' "$result_path" >&2
  exit 2
fi

jq -cS . "$result_path"
