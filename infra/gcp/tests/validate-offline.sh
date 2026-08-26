#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tofu_bin="${TOFU:-tofu}"
validation_root="$(mktemp -d)"

cleanup() {
  if [[ -n "${validation_root:-}" && -d "$validation_root" ]]; then
    rm -rf -- "$validation_root"
  fi
}
trap cleanup EXIT

command -v "$tofu_bin" >/dev/null 2>&1 || {
  printf 'ERROR: OpenTofu is required for GCP offline validation.\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for normative GCP request-hash validation.\n' >&2
  exit 1
}

cd "$repo_root"
"$tofu_bin" fmt -check -recursive infra/gcp

roots=(bootstrap platform runner)
for root_name in "${roots[@]}"; do
  root_path="infra/gcp/${root_name}"
  data_path="${validation_root}/${root_name}"
  mkdir -p "$data_path"

  TF_DATA_DIR="$data_path" "$tofu_bin" -chdir="$root_path" init \
    -backend=false \
    -input=false \
    -lockfile=readonly \
    -no-color >/dev/null
  TF_DATA_DIR="$data_path" "$tofu_bin" -chdir="$root_path" validate -no-color >/dev/null
done

sed -E \
  -e 's/\$\{[a-z_]+\}/offline-placeholder/g' \
  -e 's/\$\$\{/\$\{/g' \
  infra/gcp/runner/templates/startup.sh.tftpl >"${validation_root}/startup.sh"
bash -n "${validation_root}/startup.sh"

lock_count="$(find infra/gcp -mindepth 2 -maxdepth 2 -type f -name '.terraform.lock.hcl' | wc -l)"
[[ "$lock_count" -eq 3 ]] || {
  printf 'ERROR: expected one dependency lock file in each of the three GCP roots.\n' >&2
  exit 1
}

if rg -n \
  --glob '*.tf' \
  --glob '*.tfvars.example' \
  --glob '*.hcl' \
  'google_service_account_key|private_key|credentials[[:space:]]*=' \
  infra/gcp; then
  printf 'ERROR: GCP configuration must not contain service-account keys or embedded credentials.\n' >&2
  exit 1
fi

if rg -n 'access_config[[:space:]]*\{' infra/gcp/runner; then
  printf 'ERROR: the GCP runner must not define an external-IP access_config block.\n' >&2
  exit 1
fi

require_literal() {
  local file="$1"
  local literal="$2"
  local description="$3"

  rg -F -q -- "$literal" "$file" || {
    printf 'ERROR: missing fail-closed GCP invariant: %s\n' "$description" >&2
    return 1
  }
}

reject_literal() {
  local file="$1"
  local literal="$2"
  local description="$3"

  if rg -F -q -- "$literal" "$file"; then
    printf 'ERROR: forbidden broad GCP configuration detected: %s\n' "$description" >&2
    return 1
  fi
}

require_output_value() {
  local file="$1"
  local output_name="$2"
  local expected_value="$3"
  local description="$4"

  awk -v header="output \"${output_name}\" {" -v expected="  value       = ${expected_value}" '
    $0 == header { inside = 1; next }
    inside && $0 == expected { found = 1 }
    inside && $0 == "}" { inside = 0 }
    END { exit(found ? 0 : 1) }
  ' "$file" || {
    printf 'ERROR: missing fail-closed GCP invariant: %s\n' "$description" >&2
    return 1
  }
}

validate_policy_shape() {
  local gcp_root="$1"
  local platform_main="$gcp_root/platform/main.tf"
  local platform_outputs="$gcp_root/platform/outputs.tf"
  local runner_main="$gcp_root/runner/main.tf"
  local runner_outputs="$gcp_root/runner/outputs.tf"
  local runner_variables="$gcp_root/runner/variables.tf"
  local startup_template="$gcp_root/runner/templates/startup.sh.tftpl"

  reject_literal "$platform_main" 'resource "google_service_account" "runtime"' 'a shared persistent workload service account' || return 1
  reject_literal "$platform_main" 'runtime_data_reader' 'persistent generic workload data IAM' || return 1
  reject_literal "$platform_main" 'deployer_runtime_user' 'persistent deployer actAs IAM' || return 1
  require_literal "$runner_main" 'resource "google_service_account" "workload"' 'runner-owned unique workload identity' || return 1
  require_literal "$runner_main" 'resource "google_service_account_iam_member" "deployer_workload_user"' 'runner-owned deployer actAs grant' || return 1
  require_literal "$runner_main" 'resource "google_storage_bucket_iam_member" "data_reader"' 'runner-owned data read grant' || return 1
  require_literal "$runner_main" 'resource "google_artifact_registry_repository_iam_member" "runtime_reader"' 'runner-owned exact repository pull grant' || return 1
  require_literal "$runner_main" 'resource.name == \"projects/_/buckets/${local.platform_binding.results_bucket_name}/objects/run-specs/${var.runner_request.deployment_id}/${var.runner_request.run_spec_sha256}.json\"' 'exact run-spec object condition' || return 1
  require_literal "$runner_main" 'objects/runs/${var.runner_request.deployment_id}/results/' 'deployment results-only create prefix' || return 1
  require_literal "$runner_main" 'objects/runs/${var.runner_request.deployment_id}/logs/' 'deployment logs-only create prefix' || return 1
  require_literal "$runner_main" 'resource.name == \"projects/_/buckets/${local.platform_binding.results_bucket_name}/objects/runs/${var.runner_request.deployment_id}/control-input/execution-receipt.local.json\"' 'exact local-receipt handoff create key' || return 1
  reject_literal "$runner_main" 'objects/runs/${var.runner_request.deployment_id}/\")' 'whole-deployment results create prefix' || return 1
  require_literal "$runner_main" 'platform_binding_sha256  = sha256(jsonencode(local.platform_binding))' 'runner-side platform binding rehash' || return 1
  require_literal "$runner_main" 'request_sha256           = sha256(jsonencode(local.runner_request))' 'runner-side canonical request hash expression' || return 1
  require_literal "$runner_main" 'local.platform_binding_sha256 == var.platform_binding_sha256' 'platform binding digest equality gate' || return 1
  require_literal "$platform_outputs" 'sha256(jsonencode(local.platform_binding))' 'platform binding canonical hash' || return 1
  require_output_value "$platform_outputs" 'platform_contract_sha256' 'local.platform_binding_sha256' 'platform common contract hash alias' || return 1
  require_output_value "$runner_outputs" 'platform_contract_sha256' 'local.platform_binding_sha256' 'runner common contract hash alias' || return 1
  require_literal "$runner_variables" 'toset(keys(var.platform_binding)) == toset([' 'closed platform binding object' || return 1
  require_literal "$runner_main" 'timecmp(timestamp(), var.started_at_utc) >= 0' 'earliest apply gate' || return 1
  require_literal "$runner_main" 'timecmp(local.latest_apply_at_utc, timestamp()) >= 0' 'latest apply gate' || return 1
  require_literal "$runner_main" 'timecmp(var.deadline_utc, timeadd(var.started_at_utc, "${var.runner_request.maximum_runtime_minutes}m")) <= 0' 'absolute deadline maximum-runtime gate' || return 1
  require_literal "$platform_main" 'resource.name.startsWith(\"projects/${var.project_id}/zones/${var.region}-\")' 'publisher observer regional namespace' || return 1
  require_literal "$platform_main" 'resource.name.extract(\"/instances/{name}\").startsWith(\"ml-\")' 'publisher observer runner-name namespace' || return 1
  require_literal "$platform_main" 'resource.name.endsWith(\"/logs/bootstrap.log\")' 'publisher bounded-log read namespace' || return 1
  require_literal "$platform_main" 'resource.name.endsWith(\"/control-input/execution-receipt.local.json\")' 'publisher local-receipt read namespace' || return 1
  require_literal "$platform_main" 'objects/control/evidence/' 'publisher content-addressed evidence create namespace' || return 1
  require_literal "$platform_main" 'objects/control/receipts/' 'publisher final-receipt create namespace' || return 1
  require_literal "$platform_main" 'resource.name.endsWith(\"/completion.v1.json\")' 'publisher final-receipt filename boundary' || return 1
  reject_literal "$platform_main" 'objects/control/\")' 'publisher write access to the whole reserved control prefix' || return 1
  require_literal "$runner_main" 'bootstrap_log_object     = "runs/${var.runner_request.deployment_id}/logs/bootstrap.log"' 'bounded bootstrap log object path' || return 1
  require_literal "$startup_template" 'ifGenerationMatch=0' 'generation-zero conditional evidence create' || return 1
  require_literal "$startup_template" 'if [[ "$${GUEST_EXIT_CODE}" -eq 0 && "$${publication_exit_code}" -ne 0 ]]' 'successful guest must fail on evidence publication error' || return 1
  require_literal "$startup_template" 'MAXIMUM_BOOTSTRAP_LOG_BYTES=1048576' 'one-MiB bootstrap log bound' || return 1
  require_literal "$runner_main" 'instance_termination_action = "DELETE"' 'native max-run deletion action' || return 1
  require_literal "$runner_main" 'max_run_duration {' 'native maximum runtime' || return 1
  require_literal "$runner_main" 'resource "google_cloud_scheduler_job" "absolute_delete"' 'independent absolute delete job' || return 1
  require_literal "$runner_main" 'permissions = ["compute.instances.delete"]' 'deadline-only permission set' || return 1
  require_literal "$runner_main" 'http_method = "DELETE"' 'absolute deadline HTTP DELETE' || return 1
}

validate_policy_shape "infra/gcp"

mutation_root="${validation_root}/mutations"
mkdir -p "$mutation_root"

cp -R infra/gcp "$mutation_root/shared-identity"
printf '\nresource "google_service_account" "runtime" {}\n' >>"$mutation_root/shared-identity/platform/main.tf"
if validate_policy_shape "$mutation_root/shared-identity" >/dev/null 2>&1; then
  printf 'ERROR: mutation test accepted a shared persistent workload identity.\n' >&2
  exit 1
fi

cp -R infra/gcp "$mutation_root/broad-results"
sed -i 's#/results/#/#g' "$mutation_root/broad-results/runner/main.tf"
if validate_policy_shape "$mutation_root/broad-results" >/dev/null 2>&1; then
  printf 'ERROR: mutation test accepted a whole-deployment results writer.\n' >&2
  exit 1
fi

cp -R infra/gcp "$mutation_root/broad-run-spec"
sed -i 's/resource.name == \\"projects\/_\/buckets/resource.name.startsWith(\\"projects\/_\/buckets/g' "$mutation_root/broad-run-spec/runner/main.tf"
if validate_policy_shape "$mutation_root/broad-run-spec" >/dev/null 2>&1; then
  printf 'ERROR: mutation test accepted prefix-based run-spec or receipt access.\n' >&2
  exit 1
fi

cp -R infra/gcp "$mutation_root/unbound-platform"
sed -i 's/local.platform_binding_sha256 == var.platform_binding_sha256/true/' "$mutation_root/unbound-platform/runner/main.tf"
if validate_policy_shape "$mutation_root/unbound-platform" >/dev/null 2>&1; then
  printf 'ERROR: mutation test accepted an unverified platform binding digest.\n' >&2
  exit 1
fi

cp -R infra/gcp "$mutation_root/broad-control"
sed -i 's#/control/evidence/#/control/#g' "$mutation_root/broad-control/platform/main.tf"
if validate_policy_shape "$mutation_root/broad-control" >/dev/null 2>&1; then
  printf 'ERROR: mutation test accepted publisher write access to the whole control prefix.\n' >&2
  exit 1
fi

runner_console_vars="${validation_root}/runner-console.tfvars.json"
binding_json='{"schema_version":"1.0.0","provider":"gcp","project_id":"example-project","region":"europe-west1","state_bucket_name":"ml-state-gcp-example","data_bucket_name":"ml-data-gcp-example","results_bucket_name":"ml-results-gcp-example","artifact_repository_id":"ml","artifact_repository_uri":"europe-west1-docker.pkg.dev/example-project/ml","network_self_link":"https://www.googleapis.com/compute/v1/projects/example-project/global/networks/ml-runner","subnetwork_self_link":"https://www.googleapis.com/compute/v1/projects/example-project/regions/europe-west1/subnetworks/ml-runner-europe-west1","receipt_publisher_service_account_email":"ml-receipt-pub@example-project.iam.gserviceaccount.com","workload_results_prefix":"runs/","reserved_control_prefix":"control/","bootstrap_log_suffix":"/logs/bootstrap.log","local_receipt_handoff_suffix":"/control-input/execution-receipt.local.json","interactive_access_enabled":false}'
binding_sha256="$(printf '%s' "$binding_json" | jq -cS . | tr -d '\n' | sha256sum | cut -d' ' -f1)"
jq -n \
  --slurpfile request shared/contracts/fixtures/valid-gcp.json \
  --argjson platform_binding "$binding_json" \
  --arg platform_binding_sha256 "$binding_sha256" \
  '{
    runner_request: $request[0],
    platform_binding: $platform_binding,
    platform_binding_sha256: $platform_binding_sha256,
    deployer_principal: "user:platform-owner@example.com",
    zone: "europe-west1-b",
    boot_image: "projects/example-image-project/global/images/reviewed-runner-image-20260826",
    started_at_utc: "2026-09-01T11:00:00Z",
    deadline_utc: "2026-09-01T12:00:00Z"
  }' >"$runner_console_vars"

normative_request_sha256="$(scripts/hash-runner-request.sh shared/contracts/fixtures/valid-gcp.json)"
hash_console_root="${validation_root}/hash-console"
hash_console_data="${validation_root}/hash-console-data"
hash_console_vars="${validation_root}/hash-console.tfvars.json"
mkdir -p "$hash_console_root" "$hash_console_data"
printf '%s\n' \
  'terraform { required_version = "= 1.12.3" }' \
  'variable "runner_request" { type = any }' \
  'variable "platform_binding" { type = any }' \
  >"$hash_console_root/main.tf"
jq '{runner_request, platform_binding}' "$runner_console_vars" >"$hash_console_vars"
TF_DATA_DIR="$hash_console_data" "$tofu_bin" -chdir="$hash_console_root" init -backend=false -input=false -no-color >/dev/null
tofu_request_sha256="$(
  printf '%s\n' 'sha256(jsonencode(var.runner_request))' |
    TF_DATA_DIR="$hash_console_data" "$tofu_bin" -chdir="$hash_console_root" console -var-file="$hash_console_vars" |
    tr -d '"\r\n'
)"
[[ "$tofu_request_sha256" == "$normative_request_sha256" ]] || {
  printf 'ERROR: OpenTofu request hashing is not byte-equivalent to normative jq -cS hashing.\n' >&2
  exit 1
}

tofu_binding_sha256="$(
  printf '%s\n' 'sha256(jsonencode(var.platform_binding))' |
    TF_DATA_DIR="$hash_console_data" "$tofu_bin" -chdir="$hash_console_root" console -var-file="$hash_console_vars" |
    tr -d '"\r\n'
)"
[[ "$tofu_binding_sha256" == "$binding_sha256" ]] || {
  printf 'ERROR: the runner does not rehash the exact canonical platform binding.\n' >&2
  exit 1
}

printf 'GCP offline validation passed for bootstrap, platform, and runner. No cloud command was executed.\n'
