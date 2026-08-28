#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
azure_root="${1:-${repo_root}/infra/azure}"

fail() {
  printf 'azure-scaffold: FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "required file is missing: $1"
}

require_match() {
  local pattern="$1"
  local path="$2"
  local message="$3"
  rg -q -- "$pattern" "$path" || fail "$message"
}

require_fixed() {
  local expected="$1"
  local path="$2"
  local message="$3"
  rg -Fq -- "$expected" "$path" || fail "$message"
}

reject_match() {
  local pattern="$1"
  local path="$2"
  local message="$3"
  if rg -q -- "$pattern" "$path"; then
    fail "$message"
  fi
}

for root_kind in bootstrap platform runner; do
  root_path="${azure_root}/${root_kind}"
  [[ -d "$root_path" ]] || fail "root is missing: ${root_path}"
  require_file "${root_path}/versions.tf"
  require_file "${root_path}/provider.tf"
  require_file "${root_path}/backend.tf"
  require_file "${root_path}/.terraform.lock.hcl"
  require_match 'required_version = "= 1\.12\.3"' "${root_path}/versions.tf" \
    "${root_kind} does not pin OpenTofu 1.12.3 exactly"
  require_match 'version = "= 5\.0\.1"' "${root_path}/versions.tf" \
    "${root_kind} does not pin AzureRM 5.0.1 exactly"
  require_match 'version[[:space:]]*=[[:space:]]*"5\.0\.1"' "${root_path}/.terraform.lock.hcl" \
    "${root_kind} lock file does not select AzureRM 5.0.1"
  require_match 'provider "azurerm"' "${root_path}/provider.tf" \
    "${root_kind} does not own AzureRM provider configuration"
  require_match 'resource_provider_registrations = "none"' "${root_path}/provider.tf" \
    "${root_kind} could mutate Azure provider registrations"
  require_match 'storage_use_azuread[[:space:]]*= true' "${root_path}/provider.tf" \
    "${root_kind} does not require Entra data-plane authentication"
done

require_match 'backend "local"' "${azure_root}/bootstrap/backend.tf" \
  'bootstrap must retain local state'
reject_match 'backend "azurerm"' "${azure_root}/bootstrap" \
  'bootstrap may not depend on the backend it creates'
for remote_root in platform runner; do
  require_match 'backend "azurerm"' "${azure_root}/${remote_root}/backend.tf" \
    "${remote_root} must use its own Azure Blob backend"
  require_file "${azure_root}/${remote_root}/backend.azurerm.tfbackend.example"
  require_match 'use_azuread_auth[[:space:]]*= true' "${azure_root}/${remote_root}/backend.azurerm.tfbackend.example" \
    "${remote_root} backend example must use Entra authentication"
  reject_match '(access_key|sas_token|client_secret)[[:space:]]*=' "${azure_root}/${remote_root}/backend.azurerm.tfbackend.example" \
    "${remote_root} backend example contains a long-lived credential field"
  require_match 'storage_account_name[[:space:]]*= "stmlinfraa1b2c3"' "${azure_root}/${remote_root}/backend.azurerm.tfbackend.example" \
    "${remote_root} backend example is not bound to the accepted state-only account example"
  require_match 'container_name[[:space:]]*= "tfstate"' "${azure_root}/${remote_root}/backend.azurerm.tfbackend.example" \
    "${remote_root} backend example is not bound to the dedicated state container"
done

require_match 'public_network_access_enabled[[:space:]]*= true' "${azure_root}/bootstrap/main.tf" \
  'initial state endpoint must remain reachable until private operator connectivity is reviewed'
require_match 'shared_access_key_enabled[[:space:]]*= false' "${azure_root}/bootstrap/main.tf" \
  'state storage must disable shared-key authorization'
require_match 'versioning_enabled[[:space:]]*= true' "${azure_root}/bootstrap/main.tf" \
  'state storage must enable Blob versioning'
require_match 'prevent_destroy[[:space:]]*= true' "${azure_root}/bootstrap/main.tf" \
  'state resources must be protected from ordinary destruction'
for state_output in state_resource_group_id state_storage_account_id state_container_id; do
  require_match "output \"${state_output}\"" "${azure_root}/bootstrap/outputs.tf" \
    "bootstrap is missing state identity output ${state_output}"
done

for container in data results control; do
  require_match "resource \"azurerm_storage_container\" \"${container}\"" "${azure_root}/platform/storage.tf" \
    "platform is missing the ${container} container boundary"
done
require_match 'public_network_access_enabled[[:space:]]*= false' "${azure_root}/platform/storage.tf" \
  'workload Blob storage must be network-private'
require_match 'shared_access_key_enabled[[:space:]]*= false' "${azure_root}/platform/storage.tf" \
  'workload Blob storage must disable shared-key authorization'
require_match 'resource "azurerm_private_endpoint" "blob"' "${azure_root}/platform/storage.tf" \
  'private Blob storage is not reachable through a private endpoint'
require_match 'private_dns_zone_ids[[:space:]]*=' "${azure_root}/platform/storage.tf" \
  'Blob private endpoint is missing private DNS integration'
require_match 'prefix_match = \["results/tmp/", "control/tmp/"\]' "${azure_root}/platform/storage.tf" \
  'temporary-object cleanup is not restricted to reviewed temporary prefixes'
reject_match 'delete_after_days_since_creation' "${azure_root}/platform/storage.tf" \
  'completed Blob versions must not expire automatically in the first scaffold'
require_fixed 'var.state_storage_account_name != local.storage_account_name' "${azure_root}/platform/storage.tf" \
  'platform does not fail closed when state and workload accounts are mixed'
for state_binding in \
  'var.state_resource_group_name == local.state_resource_group_name' \
  'var.state_storage_account_name == local.state_storage_account_name' \
  'var.state_container_name == "tfstate"' \
  'lower(var.state_storage_account_id) == lower(local.state_storage_account_id)' \
  'lower(var.state_container_id) == lower(local.state_container_id)'
do
  require_fixed "$state_binding" "${azure_root}/platform/storage.tf" \
    "platform bootstrap-state identity is not exact: ${state_binding}"
done
for state_field in state_resource_group_name state_storage_account_name state_container_name state_storage_account_id state_container_id; do
  require_fixed "${state_field}" "${azure_root}/platform/locals.tf" \
    "platform interface is missing accepted state identity field ${state_field}"
done

require_match 'sku[[:space:]]*= "Basic"' "${azure_root}/platform/registry.tf" \
  'the initial ACR contract expects the simple Basic feature set'
require_match 'admin_enabled[[:space:]]*= false' "${azure_root}/platform/registry.tf" \
  'ACR admin credentials must be disabled'
require_match 'anonymous_pull_enabled[[:space:]]*= false' "${azure_root}/platform/registry.tf" \
  'ACR anonymous pull must be disabled'
require_match 'public_network_access_enabled[[:space:]]*= true' "${azure_root}/platform/registry.tf" \
  'Basic ACR must remain reachable through the explicit outbound path'

reject_match 'resource "azurerm_user_assigned_identity" "runtime"' "${azure_root}/platform/identity.tf" \
  'platform may not own a shared runtime identity that unions concurrent deployment permissions'
require_match 'resource "azurerm_user_assigned_identity" "receipt_publisher"' "${azure_root}/platform/identity.tf" \
  'distinct receipt-publisher identity is missing'
require_match 'scope[[:space:]]*= azurerm_storage_container.control.id' "${azure_root}/platform/identity.tf" \
  'receipt publisher is not scoped to the reserved control container'
reject_match 'runtime_control' "${azure_root}/platform/identity.tf" \
  'runtime identity gained a control-container assignment'
reject_match 'runtime_results_writer' "${azure_root}/platform/identity.tf" \
  'platform may not grant the runtime identity broad results-container write access'
reject_match 'runtime_data_reader|runtime_registry_pull' "${azure_root}/platform/identity.tf" \
  'per-deployment runtime grants must remain in runner state'
require_match 'blobs/delete' "${azure_root}/platform/identity.tf" \
  'custom Blob writer role must state the delete exclusion explicitly'
writer_role_block="$(sed -n '/resource "azurerm_role_definition" "blob_create_write_no_delete"/,/assignable_scopes/p' "${azure_root}/platform/identity.tf")"
[[ "$writer_role_block" == *'/blobs/write"'* && "$writer_role_block" == *'/blobs/add/action"'* ]] ||
  fail 'custom Blob writer role is missing create/write actions'
[[ "$writer_role_block" != *'/blobs/read"'* ]] ||
  fail 'custom Blob writer role must not grant blob read'
publisher_reader_block="$(sed -n '/resource "azurerm_role_assignment" "publisher_results_reader"/,/^}/p' "${azure_root}/platform/identity.tf")"
[[ "$publisher_reader_block" == *"condition_version    = \"2.0\""* ]] ||
  fail 'publisher evidence reader must use Azure ABAC condition version 2.0'
[[ "$publisher_reader_block" == *"StringLike 'runs/*/control-input/execution-receipt.local.json'"* ]] ||
  fail 'publisher read must be limited to exact local-receipt handoff patterns'
[[ "$publisher_reader_block" == *"StringLike 'runs/*/logs/bootstrap.log'"* ]] ||
  fail 'publisher read must be limited to exact bounded bootstrap-log patterns'
[[ "$publisher_reader_block" == *"SubOperationMatches{'Blob.List'}"* ]] ||
  fail 'publisher evidence reader must deny Blob listing'

reject_match 'resource "azurerm_nat_gateway"|resource "azurerm_public_ip"' "${azure_root}/platform/network.tf" \
  'persistent platform networking contains runner-only egress resources'
require_match 'name[[:space:]]*= "DenyAllInbound"' "${azure_root}/platform/network.tf" \
  'runner subnet lacks an explicit no-ingress rule'
require_fixed 'access                     = "Deny"' "${azure_root}/platform/network.tf" \
  'runner subnet inbound rule must deny traffic'
require_match 'private_dns_zone_id[[:space:]]*= azurerm_private_dns_zone.blob.id' "${azure_root}/platform/network.tf" \
  'runner VNet is not linked to private Blob DNS'

reject_match 'resource "azurerm_(storage|container_registry|virtual_network)' "${azure_root}/runner" \
  'runner state contains a persistent platform resource'
require_match 'resource "azurerm_user_assigned_identity" "runtime"' "${azure_root}/runner/main.tf" \
  'runner state must own one unique per-deployment runtime identity'
require_match 'resource "azurerm_public_ip" "runner"' "${azure_root}/runner/main.tf" \
  'runner state must own its disposable outbound address'
require_match 'public_ip_address_id[[:space:]]*= azurerm_public_ip.runner.id' "${azure_root}/runner/main.tf" \
  'runner NIC is not bound to its disposable outbound address'
require_match 'allocation_method[[:space:]]*= "Static"' "${azure_root}/runner/main.tf" \
  'Azure Standard runner public IP must use static allocation'
require_match 'disable_password_authentication[[:space:]]*= true' "${azure_root}/runner/main.tf" \
  'runner VM must disable password authentication'
require_match 'identity_ids[[:space:]]*= \[azurerm_user_assigned_identity.runtime.id\]' "${azure_root}/runner/main.tf" \
  'runner VM must attach only the reviewed runtime identity'
reject_match 'identity_ids[[:space:]]*=.*receipt_publisher' "${azure_root}/runner/main.tf" \
  'receipt-publisher identity must remain unavailable to the VM'
reject_match 'principal_id[[:space:]]*=.*receipt_publisher' "${azure_root}/runner/access.tf" \
  'receipt-publisher principal must remain unavailable to runner role assignments'
require_match 'encryption_at_host_enabled[[:space:]]*= true' "${azure_root}/runner/main.tf" \
  'runner VM must enable host encryption'
require_match 'resource "azurerm_dev_test_global_vm_shutdown_schedule" "deadline"' "${azure_root}/runner/main.tf" \
  'Azure native auto-shutdown schedule is missing'
require_match 'daily_recurrence_time[[:space:]]*= local.shutdown_time_utc' "${azure_root}/runner/main.tf" \
  'native shutdown is not bound to the reviewed absolute deadline'
require_match 'plantimestamp\(\)' "${azure_root}/runner/main.tf" \
  'runner plan lacks a plan-time deadline gate'
require_match 'timestamp\(\)' "${azure_root}/runner/main.tf" \
  'runner apply lacks a fresh latest-apply gate'
require_fixed 'latest_apply_at_utc = timeadd(var.started_at_utc, "5m")' "${azure_root}/runner/locals.tf" \
  'latest-apply must close exactly five minutes after the reviewed earliest apply'
require_fixed 'timecmp(timestamp(), var.started_at_utc) >= 0' "${azure_root}/runner/main.tf" \
  'runner apply gate does not enforce the reviewed earliest apply timestamp'
require_fixed 'timecmp(timestamp(), local.latest_apply_at_utc) <= 0' "${azure_root}/runner/main.tf" \
  'runner apply gate does not enforce the reviewed latest apply timestamp'
require_fixed 'timecmp(var.deadline_utc, local.latest_apply_at_utc) > 0' "${azure_root}/runner/main.tf" \
  'runner does not require the deadline after the closed apply window'
require_fixed 'timecmp(var.deadline_utc, timeadd(var.started_at_utc, "${var.runner_request.maximum_runtime_minutes}m")) <= 0' "${azure_root}/runner/main.tf" \
  'runner deadline may exceed the accepted maximum runtime window'
require_fixed 'var.backend_key == local.expected_backend_key' "${azure_root}/runner/main.tf" \
  'runner does not bind the deterministic backend key'
require_fixed 'var.state_storage_account_name != local.storage_account_name' "${azure_root}/runner/main.tf" \
  'runner does not keep external backend storage separate from workload storage'
require_fixed 'lower(var.state_container_id) == lower(local.state_container_id)' "${azure_root}/runner/main.tf" \
  'runner does not bind the exact accepted backend container identity'
require_fixed 'var.platform_contract_sha256 == sha256(jsonencode(local.platform_interface))' "${azure_root}/runner/main.tf" \
  'runner does not verify the accepted persistent-platform interface checksum'
require_match 'filebase64\("\$\{path.module\}/../../../shared/bootstrap/guest-runner.sh"\)' "${azure_root}/runner/main.tf" \
  'runner does not embed the accepted portable guest timeout core'
require_match 'variable "runner_request"' "${azure_root}/runner/variables.tf" \
  'runner must accept one closed common request object'
require_fixed '"provider",' "${azure_root}/runner/variables.tf" \
  'closed runner request must retain the exact common provider field name'
require_fixed 'length(keys(var.runner_request)) == 11' "${azure_root}/runner/variables.tf" \
  'runner_request must reject unknown or missing fields instead of silently converting them'
for top_level_request_field in cloud_provider deployment_id oci_repository oci_digest run_spec_uri run_spec_sha256 run_spec_object_version resource_profile capacity_mode maximum_runtime_minutes; do
  reject_match "variable \"${top_level_request_field}\"" "${azure_root}/runner/variables.tf" \
    "common request field escaped the closed runner_request object: ${top_level_request_field}"
done
require_match 'resource "azurerm_role_assignment" "runtime_data_reader"' "${azure_root}/runner/access.tf" \
  'runner state lacks the per-deployment data-reader assignment'
require_match 'resource "azurerm_role_assignment" "runtime_registry_pull"' "${azure_root}/runner/access.tf" \
  'runner state lacks the per-deployment registry-pull assignment'
require_match 'resource "azurerm_role_assignment" "runtime_run_spec_reader"' "${azure_root}/runner/access.tf" \
  'runner lacks the exact run-spec reader assignment'
require_fixed "StringEquals '\${local.run_spec_blob_path}'" "${azure_root}/runner/access.tf" \
  'run-spec reader is not ABAC-bound to the exact immutable object path'
require_match "SubOperationMatches\{'Blob.List'\}" "${azure_root}/runner/access.tf" \
  'run-spec reader does not explicitly deny list access'
require_match 'resource "azurerm_role_assignment" "runtime_deployment_writer"' "${azure_root}/runner/access.tf" \
  'runner lacks the deployment-scoped writer assignment'
require_fixed "StringEquals '\${local.log_blob_path}'" "${azure_root}/runner/access.tf" \
  'deployment writer must bind only the exact bounded bootstrap-log object'
require_fixed "StringLike '\${local.result_blob_prefix}*'" "${azure_root}/runner/access.tf" \
  'deployment writer is missing the exact results prefix'
require_fixed "StringEquals '\${local.handoff_blob_path}'" "${azure_root}/runner/access.tf" \
  'deployment writer must bind only the exact local-receipt handoff object'
reject_match 'log_blob_prefix|handoff_blob_prefix' "${azure_root}/runner" \
  'runner ABAC must not broaden the log or local-receipt handoff into prefixes'
require_match 'condition_version[[:space:]]*= "2\.0"' "${azure_root}/runner/access.tf" \
  'runner Blob assignments must use Azure ABAC condition version 2.0'
reject_match 'control/receipts|control/evidence' "${azure_root}/runner" \
  'runner state may not grant or configure final control-prefix access'

require_file "${azure_root}/runner/azure-runner-wrapper.sh"
bash -n "${azure_root}/runner/azure-runner-wrapper.sh"
reject_match '(^|[^A-Za-z])eval([^A-Za-z]|$)|bash -c|sh -c' "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper may not evaluate shell text'
require_match 'ML_CONTAINER_RUNTIME_PATH="/usr/bin/docker"' "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper must select one fixed prepared-image runtime path'
require_match '/opt/ml/bin/guest-runner.sh' "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper does not invoke the portable guest core'
require_match 'runs/\$\{DEPLOYMENT_ID\}/control-input/execution-receipt\.local\.json' "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper is missing the exact local-receipt handoff path'
require_match 'runs/\$\{DEPLOYMENT_ID\}/logs/bootstrap\.log' "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper must persist the bounded log at the exact reviewed log object'
require_fixed "--if-none-match '*'" "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper handoffs must use an explicit atomic If-None-Match create'
require_match '/usr/bin/tail -c 1048576' "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper does not bound its bootstrap-log handoff'
require_match 'guest_exit_code=\$\?' "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper does not capture the guest exit code'
require_match 'wrapper_exit_code=74' "${azure_root}/runner/azure-runner-wrapper.sh" \
  'Azure wrapper could preserve a success exit after a failed authoritative handoff'
bounded_log_failure_block="$(sed -n '/bounded bootstrap log creation failed/,/^[[:space:]]*fi$/p' "${azure_root}/runner/azure-runner-wrapper.sh")"
[[ "$bounded_log_failure_block" == *'wrapper_exit_code=74'* ]] ||
  fail 'missing bounded-log evidence can preserve an otherwise successful guest exit'
trap_line="$(rg -n 'trap finish EXIT' "${azure_root}/runner/azure-runner-wrapper.sh" | head -1 | cut -d: -f1)"
check_line="$(rg -n '^for required_path in' "${azure_root}/runner/azure-runner-wrapper.sh" | head -1 | cut -d: -f1)"
[[ -n "$trap_line" && -n "$check_line" && "$trap_line" -lt "$check_line" ]] ||
  fail 'logging/finalization must be installed before prepared-image checks'

reject_match 'variable "(access_key|storage_key|sas_token|client_secret|client_password|private_key)"' "$azure_root" \
  'Azure root exposes a forbidden long-lived credential input'
reject_match 'provisioner "(local-exec|remote-exec)"' "$azure_root" \
  'Azure scaffold may not run arbitrary provisioners'

for output_name in deployment_id provider runner_id workload_identity resolved_profile deadline data_uri results_uri receipt_uri request_sha256 platform_contract_sha256 management_hint backend_key; do
  require_match "output \"${output_name}\"" "${azure_root}/runner/outputs.tf" \
    "runner is missing common output ${output_name}"
done
require_match 'az vm show' "${azure_root}/runner/outputs.tf" \
  'management_hint must use a read-only Azure VM observation command'
reject_match 'run-command|RunShellScript' "${azure_root}/runner/outputs.tf" \
  'management_hint may not invoke mutable Azure Run Command'

printf 'azure-scaffold: PASS (offline policy checks only; no Azure command executed)\n'
