#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s RECEIPT.json\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq is required to validate completion receipts.\n' >&2
  exit 3
fi

receipt_path=$1
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profiles_path="$repo_root/shared/contracts/resource-profiles.json"

if [[ ! -f "$receipt_path" ]]; then
  printf 'ERROR: completion receipt is not a regular file: %s\n' "$receipt_path" >&2
  exit 2
fi

if ! jq -e --slurpfile profiles "$profiles_path" '
  . as $receipt
  | type == "object"
    and (([
      "capacity_mode",
      "container_exit_code",
      "control_evidence_sha256",
      "control_evidence_uri",
      "deadline",
      "deployment_id",
      "account_scope",
      "backend_key",
      "finished_at",
      "log_sha256",
      "maximum_runtime_minutes",
      "oci_digest",
      "oci_repository",
      "platform_contract_sha256",
      "provider",
      "publication_mode",
      "receipt_publisher_identity",
      "receipt_uri",
      "region",
      "request_sha256",
      "resolved_machine_type",
      "resolved_memory_mib",
      "resolved_vcpu",
      "resource_profile",
      "results_uri",
      "run_spec_object_version",
      "run_spec_sha256",
      "run_spec_uri",
      "runner_id",
      "schema_version",
      "started_at",
      "status",
      "terminal",
      "workload_identity"
    ] - (keys)) | length == 0)
    and (((keys) - [
      "capacity_mode",
      "container_exit_code",
      "control_evidence_sha256",
      "control_evidence_uri",
      "deadline",
      "deployment_id",
      "account_scope",
      "backend_key",
      "finished_at",
      "log_sha256",
      "local_execution_receipt_sha256",
      "maximum_runtime_minutes",
      "oci_digest",
      "oci_repository",
      "platform_contract_sha256",
      "provider",
      "publication_mode",
      "receipt_publisher_identity",
      "receipt_uri",
      "region",
      "request_sha256",
      "resolved_machine_type",
      "resolved_memory_mib",
      "resolved_vcpu",
      "resource_profile",
      "result_manifest_sha256",
      "results_uri",
      "run_spec_object_version",
      "run_spec_sha256",
      "run_spec_uri",
      "runner_id",
      "schema_version",
      "started_at",
      "status",
      "terminal",
      "workload_identity"
    ]) | length == 0)
    and ($receipt.schema_version == "1.0.0")
    and ($receipt.terminal == true)
    and (($receipt.deployment_id | type) == "string")
    and ($receipt.deployment_id | test("^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$"))
    and (["aws", "gcp", "azure"] | index($receipt.provider) != null)
    and (($receipt.account_scope | type) == "string")
    and ($receipt.account_scope | test("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$"))
    and (($receipt.region | type) == "string")
    and ($receipt.region | test("^[a-z0-9][a-z0-9-]{1,63}$"))
    and ($receipt.backend_key == (
      $receipt.provider + "/" + $receipt.account_scope + "/" + $receipt.region
      + "/runner/" + $receipt.deployment_id + ".tfstate"
    ))
    and ($receipt.request_sha256 | test("^[0-9a-f]{64}$"))
    and ($receipt.platform_contract_sha256 | test("^[0-9a-f]{64}$"))
    and (($receipt.runner_id | type) == "string")
    and ($receipt.runner_id | test("^[^[:cntrl:]]{1,512}$"))
    and (($receipt.workload_identity | type) == "string")
    and ($receipt.workload_identity | test("^[^[:cntrl:]]{1,512}$"))
    and (($receipt.receipt_publisher_identity | type) == "string")
    and ($receipt.receipt_publisher_identity | test("^[^[:cntrl:]]{1,512}$"))
    and ($receipt.receipt_publisher_identity != $receipt.workload_identity)
    and ($receipt.publication_mode == "control_identity_conditional_create")
    and ($receipt.control_evidence_sha256 | test("^[0-9a-f]{64}$"))
    and ($receipt.control_evidence_uri | endswith(
      "/control/evidence/" + $receipt.deployment_id + "/"
      + $receipt.control_evidence_sha256 + ".json"
    ))
    and (($receipt.control_evidence_uri | test("[?#[:space:]]")) | not)
    and (
      if $receipt | has("local_execution_receipt_sha256") then
        ($receipt.local_execution_receipt_sha256 | test("^[0-9a-f]{64}$"))
      else
        true
      end
    )
    and ($receipt.receipt_uri | endswith(
      "/control/receipts/" + $receipt.deployment_id + "/completion.v1.json"
    ))
    and (($receipt.receipt_uri | test("[?#[:space:]]")) | not)
    and (($receipt.oci_repository | type) == "string")
    and (($receipt.oci_repository | length) >= 3 and ($receipt.oci_repository | length) <= 255)
    and (($receipt.oci_digest | type) == "string")
    and ($receipt.oci_digest | test("^sha256:[0-9a-f]{64}$"))
    and (($receipt.run_spec_sha256 | type) == "string")
    and ($receipt.run_spec_sha256 | test("^[0-9a-f]{64}$"))
    and ($receipt.run_spec_uri | endswith(
      "/run-specs/" + $receipt.deployment_id + "/" + $receipt.run_spec_sha256 + ".json"
    ))
    and (($receipt.run_spec_uri | test("[?#[:space:]]")) | not)
    and (($receipt.run_spec_object_version | type) == "string")
    and ($receipt.run_spec_object_version | test("^[^[:cntrl:][:space:]]{1,512}$"))
    and ($profiles[0].profiles | has($receipt.resource_profile))
    and (($receipt.resolved_machine_type | type) == "string")
    and ($receipt.resolved_machine_type | test("^[^[:cntrl:]]{1,255}$"))
    and (($receipt.resolved_vcpu | type) == "number")
    and ($receipt.resolved_vcpu == ($receipt.resolved_vcpu | floor))
    and ($receipt.resolved_vcpu >= $profiles[0].profiles[$receipt.resource_profile].minimum_vcpu)
    and (($receipt.resolved_memory_mib | type) == "number")
    and ($receipt.resolved_memory_mib == ($receipt.resolved_memory_mib | floor))
    and ($receipt.resolved_memory_mib >= $profiles[0].profiles[$receipt.resource_profile].minimum_memory_mib)
    and ($receipt.capacity_mode == "standard")
    and (($receipt.maximum_runtime_minutes | type) == "number")
    and ($receipt.maximum_runtime_minutes == ($receipt.maximum_runtime_minutes | floor))
    and ($receipt.maximum_runtime_minutes >= $profiles[0].maximum_runtime_minutes.minimum)
    and ($receipt.maximum_runtime_minutes <= $profiles[0].maximum_runtime_minutes.maximum)
    and (($receipt.started_at | fromdateiso8601) <= ($receipt.finished_at | fromdateiso8601))
    and (($receipt.started_at | fromdateiso8601) < ($receipt.deadline | fromdateiso8601))
    and (
      (($receipt.deadline | fromdateiso8601) - ($receipt.started_at | fromdateiso8601))
      <= ($receipt.maximum_runtime_minutes * 60)
    )
    and (["succeeded", "failed", "timed_out", "interrupted", "bootstrap_failed"] | index($receipt.status) != null)
    and (($receipt.container_exit_code | type) == "number")
    and ($receipt.container_exit_code == ($receipt.container_exit_code | floor))
    and ($receipt.container_exit_code >= -1 and $receipt.container_exit_code <= 255)
    and (
      if $receipt.status == "succeeded" then
        $receipt.container_exit_code == 0
        and ($receipt | has("local_execution_receipt_sha256"))
        and ($receipt | has("result_manifest_sha256"))
        and (($receipt.finished_at | fromdateiso8601) <= ($receipt.deadline | fromdateiso8601))
      elif $receipt.status == "bootstrap_failed" then
        $receipt.container_exit_code == -1
        and (($receipt | has("local_execution_receipt_sha256")) | not)
        and (($receipt | has("result_manifest_sha256")) | not)
      elif $receipt.status == "timed_out" then
        $receipt.container_exit_code == 124
        and ($receipt | has("local_execution_receipt_sha256"))
      elif $receipt.status == "failed" then
        $receipt.container_exit_code >= 1
        and ($receipt | has("local_execution_receipt_sha256"))
      else
        $receipt.container_exit_code >= 1
      end
    )
    and (
      if $receipt | has("result_manifest_sha256") then
        ($receipt.result_manifest_sha256 | test("^[0-9a-f]{64}$"))
      else
        true
      end
    )
    and ($receipt.log_sha256 | test("^[0-9a-f]{64}$"))
    and ($receipt.results_uri | endswith("/runs/" + $receipt.deployment_id + "/results/"))
    and (
      if $receipt.provider == "aws" then
        ($receipt.oci_repository | test("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/"))
        and ($receipt.run_spec_uri | startswith("s3://"))
        and ($receipt.results_uri | startswith("s3://"))
        and ($receipt.receipt_uri | startswith("s3://"))
        and ($receipt.control_evidence_uri | startswith("s3://"))
      elif $receipt.provider == "gcp" then
        ($receipt.oci_repository | test("^[a-z0-9-]+-docker\\.pkg\\.dev/"))
        and ($receipt.run_spec_uri | startswith("gs://"))
        and ($receipt.results_uri | startswith("gs://"))
        and ($receipt.receipt_uri | startswith("gs://"))
        and ($receipt.control_evidence_uri | startswith("gs://"))
      else
        ($receipt.oci_repository | test("^[a-z0-9]{5,50}\\.azurecr\\.io/"))
        and ($receipt.run_spec_uri | test("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/"))
        and ($receipt.results_uri | test("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/"))
        and ($receipt.receipt_uri | test("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/"))
        and ($receipt.control_evidence_uri | test("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/"))
      end
    )
' "$receipt_path" >/dev/null; then
  printf 'ERROR: completion receipt violates the frozen Goal 02 contract: %s\n' "$receipt_path" >&2
  exit 2
fi

jq -cS . "$receipt_path"
