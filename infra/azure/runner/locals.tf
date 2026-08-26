locals {
  deployment_name_token = substr(var.runner_request.deployment_id, 0, 16)
  deployment_name_hash  = substr(sha256(var.runner_request.deployment_id), 0, 12)
  name_prefix           = "${var.project_name}-az-${local.deployment_name_token}-${local.deployment_name_hash}-${var.uniqueness_suffix}"
  resource_group_name   = "${local.name_prefix}-runner"
  project_slug          = replace(var.project_name, "-", "")

  platform_name_prefix         = "${var.project_name}-azure-${var.uniqueness_suffix}"
  platform_resource_group_name = "${var.project_name}-azure-platform-${var.uniqueness_suffix}"
  platform_resource_group_id   = "/subscriptions/${lower(var.subscription_id)}/resourceGroups/${local.platform_resource_group_name}"
  storage_account_name         = "ml${local.project_slug}${var.uniqueness_suffix}"
  storage_account_id           = "${local.platform_resource_group_id}/providers/Microsoft.Storage/storageAccounts/${local.storage_account_name}"
  registry_name                = "acr${local.project_slug}${var.uniqueness_suffix}"
  state_resource_group_name    = "${var.project_name}-azure-state-${var.uniqueness_suffix}"
  state_storage_account_name   = "st${local.project_slug}${var.uniqueness_suffix}"
  state_storage_account_id     = "/subscriptions/${lower(var.subscription_id)}/resourceGroups/${local.state_resource_group_name}/providers/Microsoft.Storage/storageAccounts/${local.state_storage_account_name}"
  state_container_id           = "${local.state_storage_account_id}/blobServices/default/containers/tfstate"

  expected_backend_key                   = "azure/${lower(var.subscription_id)}/${var.location}/runner/${var.runner_request.deployment_id}.tfstate"
  expected_subnet_id                     = "${local.platform_resource_group_id}/providers/Microsoft.Network/virtualNetworks/${local.platform_name_prefix}-vnet/subnets/runner"
  expected_receipt_publisher_identity_id = "${local.platform_resource_group_id}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${local.platform_name_prefix}-receipt-publisher"
  expected_data_container_id             = "${local.storage_account_id}/blobServices/default/containers/data"
  expected_results_container_id          = "${local.storage_account_id}/blobServices/default/containers/results"
  expected_control_container_id          = "${local.storage_account_id}/blobServices/default/containers/control"
  expected_data_uri                      = "https://${local.storage_account_name}.blob.core.windows.net/data/"
  expected_results_container_uri         = "https://${local.storage_account_name}.blob.core.windows.net/results"
  expected_control_container_uri         = "https://${local.storage_account_name}.blob.core.windows.net/control"
  expected_registry_id                   = "${local.platform_resource_group_id}/providers/Microsoft.ContainerRegistry/registries/${local.registry_name}"
  expected_registry_login_server         = "${local.registry_name}.azurecr.io"

  profiles = {
    smoke = {
      vm_size    = "Standard_D2s_v5"
      vcpu       = 2
      memory_mib = 8192
    }
    balanced = {
      vm_size    = "Standard_D4s_v5"
      vcpu       = 4
      memory_mib = 16384
    }
    highmem = {
      vm_size    = "Standard_E4s_v5"
      vcpu       = 4
      memory_mib = 32768
    }
  }

  resolved_profile    = local.profiles[var.runner_request.resource_profile]
  results_uri         = "${var.results_container_uri}/runs/${var.runner_request.deployment_id}/results/"
  receipt_uri         = "${var.control_container_uri}/receipts/${var.runner_request.deployment_id}/completion.v1.json"
  expected_run_spec   = "${var.results_container_uri}/run-specs/${var.runner_request.deployment_id}/${var.runner_request.run_spec_sha256}.json"
  run_spec_blob_path  = "run-specs/${var.runner_request.deployment_id}/${var.runner_request.run_spec_sha256}.json"
  log_blob_path       = "runs/${var.runner_request.deployment_id}/logs/bootstrap.log"
  result_blob_prefix  = "runs/${var.runner_request.deployment_id}/results/"
  handoff_blob_path   = "runs/${var.runner_request.deployment_id}/control-input/execution-receipt.local.json"
  shutdown_time_utc   = replace(substr(var.deadline_utc, 11, 5), ":", "")
  latest_apply_at_utc = timeadd(var.started_at_utc, "5m")

  platform_interface = {
    schema_version                         = "1.0.0"
    provider                               = "azure"
    subscription_id                        = var.subscription_id
    location                               = var.location
    state_resource_group_name              = var.state_resource_group_name
    state_storage_account_name             = var.state_storage_account_name
    state_container_name                   = var.state_container_name
    state_storage_account_id               = var.state_storage_account_id
    state_container_id                     = var.state_container_id
    data_container_id                      = var.data_container_id
    data_uri                               = var.data_uri
    results_container_id                   = var.results_container_id
    results_container_uri                  = var.results_container_uri
    control_container_id                   = var.control_container_id
    control_container_uri                  = var.control_container_uri
    container_registry_id                  = var.container_registry_id
    container_registry_login_server        = var.container_registry_login_server
    runner_subnet_id                       = var.subnet_id
    results_blob_writer_role_definition_id = var.results_blob_writer_role_definition_id
    receipt_publisher_identity_id          = var.receipt_publisher_identity_id
    receipt_publisher_principal_id         = var.receipt_publisher_principal_id
  }

  request_sha256 = sha256(jsonencode(var.runner_request))

  guest_request = merge(var.runner_request, {
    acr_name                   = local.registry_name
    runtime_identity_client_id = azurerm_user_assigned_identity.runtime.client_id
    data_uri                   = var.data_uri
    results_uri                = local.results_uri
  })

  tags = {
    deployment-id = var.runner_request.deployment_id
    managed-by    = "opentofu"
    owner         = var.owner
    project       = var.project_name
    provider      = "azure"
    root-kind     = "runner"
  }
}
