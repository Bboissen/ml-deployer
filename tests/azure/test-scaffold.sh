#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="${repo_root}/scripts/azure/validate-scaffold.sh"
azure_root="${repo_root}/infra/azure"

fail() {
  printf 'test-azure-scaffold: FAIL: %s\n' "$1" >&2
  exit 1
}

expect_rejected() {
  local case_name="$1"
  local candidate_root="$2"
  if "$validator" "$candidate_root" >/dev/null 2>&1; then
    fail "unsafe fixture was accepted: ${case_name}"
  fi
}

"$validator" "$azure_root"

test_cache_root="${XDG_CACHE_HOME:-/var/tmp}/ray-terraform-tests-${UID}"
mkdir -p "$test_cache_root"
chmod 700 "$test_cache_root"
temporary_directory="$(mktemp -d "${test_cache_root}/azure-scaffold.XXXXXX")"
trap 'find "$temporary_directory" -depth -delete' EXIT

for root_name in bootstrap platform runner; do
  terraform_data_directory="${temporary_directory}/terraform-${root_name}"
  mkdir -p "$terraform_data_directory"
  TF_DATA_DIR="$terraform_data_directory" tofu \
    -chdir="${azure_root}/${root_name}" init \
    -backend=false -input=false -lockfile=readonly -no-color >/dev/null
  TF_DATA_DIR="$terraform_data_directory" tofu \
    -chdir="${azure_root}/${root_name}" validate -no-color >/dev/null
done

mkdir -p "${temporary_directory}/request-hash"
request_fixture="${repo_root}/shared/contracts/fixtures/valid-azure.json"
expected_request_sha256="$("${repo_root}/scripts/hash-runner-request.sh" "$request_fixture")"
terraform_request_sha256="$(
  printf 'sha256(jsonencode(jsondecode(file("%s"))))\n' "$request_fixture" |
    tofu -chdir="${temporary_directory}/request-hash" console -no-color |
    tr -d '"'
)"
[[ "$terraform_request_sha256" == "$expected_request_sha256" ]] ||
  fail 'OpenTofu request hashing differs from the normative jq -cS request hash'

cp -R "$azure_root" "${temporary_directory}/shared-key"
sed -i '0,/shared_access_key_enabled[[:space:]]*= false/s//shared_access_key_enabled = true/' \
  "${temporary_directory}/shared-key/bootstrap/main.tf"
expect_rejected shared-key "${temporary_directory}/shared-key"

cp -R "$azure_root" "${temporary_directory}/inbound-runner"
sed -i '0,/access[[:space:]]*= "Deny"/s//access = "Allow"/' \
  "${temporary_directory}/inbound-runner/platform/network.tf"
expect_rejected inbound-runner "${temporary_directory}/inbound-runner"

cp -R "$azure_root" "${temporary_directory}/missing-deadline"
sed -i 's/azurerm_dev_test_global_vm_shutdown_schedule/azurerm_disabled_shutdown_schedule/' \
  "${temporary_directory}/missing-deadline/runner/main.tf"
expect_rejected missing-deadline "${temporary_directory}/missing-deadline"

cp -R "$azure_root" "${temporary_directory}/acr-admin"
sed -i 's/admin_enabled[[:space:]]*= false/admin_enabled = true/' \
  "${temporary_directory}/acr-admin/platform/registry.tf"
expect_rejected acr-admin "${temporary_directory}/acr-admin"

cp -R "$azure_root" "${temporary_directory}/broad-writer"
sed -i '/data_actions = \[/a\      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",' \
  "${temporary_directory}/broad-writer/platform/identity.tf"
expect_rejected broad-writer "${temporary_directory}/broad-writer"

cp -R "$azure_root" "${temporary_directory}/missing-handoff-prefix"
sed -i "s/StringEquals '\${local.handoff_blob_path}'/StringLike 'runs\/*\/*'/g" \
  "${temporary_directory}/missing-handoff-prefix/runner/access.tf"
expect_rejected missing-handoff-prefix "${temporary_directory}/missing-handoff-prefix"

cp -R "$azure_root" "${temporary_directory}/broad-log-prefix"
sed -i "s/StringEquals '\${local.log_blob_path}'/StringLike 'runs\/*\/logs\/*'/g" \
  "${temporary_directory}/broad-log-prefix/runner/access.tf"
expect_rejected broad-log-prefix "${temporary_directory}/broad-log-prefix"

cp -R "$azure_root" "${temporary_directory}/broad-publisher-read"
sed -i "s#runs/\*/control-input/execution-receipt.local.json#runs/*#" \
  "${temporary_directory}/broad-publisher-read/platform/identity.tf"
expect_rejected broad-publisher-read "${temporary_directory}/broad-publisher-read"

cp -R "$azure_root" "${temporary_directory}/shared-runtime-identity"
printf '\nresource "azurerm_user_assigned_identity" "runtime" {}\n' \
  >>"${temporary_directory}/shared-runtime-identity/platform/identity.tf"
expect_rejected shared-runtime-identity "${temporary_directory}/shared-runtime-identity"

cp -R "$azure_root" "${temporary_directory}/mutable-management-hint"
sed -i 's/az vm show/az vm run-command invoke/' \
  "${temporary_directory}/mutable-management-hint/runner/outputs.tf"
expect_rejected mutable-management-hint "${temporary_directory}/mutable-management-hint"

cp -R "$azure_root" "${temporary_directory}/renamed-provider-field"
sed -i '0,/"provider",/s//"cloud_provider",/' \
  "${temporary_directory}/renamed-provider-field/runner/variables.tf"
expect_rejected renamed-provider-field "${temporary_directory}/renamed-provider-field"

cp -R "$azure_root" "${temporary_directory}/missing-earliest-apply"
sed -i 's/timecmp(timestamp(), var.started_at_utc) >= 0/timecmp(timestamp(), var.started_at_utc) <= 0/' \
  "${temporary_directory}/missing-earliest-apply/runner/main.tf"
expect_rejected missing-earliest-apply "${temporary_directory}/missing-earliest-apply"

cp -R "$azure_root" "${temporary_directory}/wide-apply-window"
sed -i 's/timeadd(var.started_at_utc, "5m")/timeadd(var.started_at_utc, "10m")/' \
  "${temporary_directory}/wide-apply-window/runner/locals.tf"
expect_rejected wide-apply-window "${temporary_directory}/wide-apply-window"

cp -R "$azure_root" "${temporary_directory}/mixed-state-workload"
sed -i 's/var.state_storage_account_name != local.storage_account_name/var.state_storage_account_name == local.storage_account_name/' \
  "${temporary_directory}/mixed-state-workload/platform/storage.tf"
expect_rejected mixed-state-workload "${temporary_directory}/mixed-state-workload"

cp -R "$azure_root" "${temporary_directory}/workload-backend"
sed -i 's/storage_account_name = "stmlinfraa1b2c3"/storage_account_name = "mlmlinfraa1b2c3"/' \
  "${temporary_directory}/workload-backend/runner/backend.azurerm.tfbackend.example"
expect_rejected workload-backend "${temporary_directory}/workload-backend"

cp -R "$azure_root" "${temporary_directory}/unbound-state-identity"
sed -i 's/var.state_resource_group_name == local.state_resource_group_name/var.state_resource_group_name != local.state_resource_group_name/' \
  "${temporary_directory}/unbound-state-identity/platform/storage.tf"
expect_rejected unbound-state-identity "${temporary_directory}/unbound-state-identity"

cp -R "$azure_root" "${temporary_directory}/missing-log-evidence-failure"
sed -i '/bounded bootstrap log creation failed/,/^[[:space:]]*fi$/ s/wrapper_exit_code=74/wrapper_exit_code=0/' \
  "${temporary_directory}/missing-log-evidence-failure/runner/azure-runner-wrapper.sh"
expect_rejected missing-log-evidence-failure "${temporary_directory}/missing-log-evidence-failure"

printf 'test-azure-scaffold: PASS (1 valid, canonical request hash, and 17 fail-closed cases)\n'
