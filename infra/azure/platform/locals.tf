locals {
  project_slug               = replace(var.project_name, "-", "")
  name_prefix                = "${var.project_name}-azure-${var.uniqueness_suffix}"
  resource_group_name        = "${var.project_name}-azure-platform-${var.uniqueness_suffix}"
  storage_account_name       = "ml${local.project_slug}${var.uniqueness_suffix}"
  registry_name              = "acr${local.project_slug}${var.uniqueness_suffix}"
  state_resource_group_name  = "${var.project_name}-azure-state-${var.uniqueness_suffix}"
  state_storage_account_name = "st${local.project_slug}${var.uniqueness_suffix}"
  state_storage_account_id   = "/subscriptions/${lower(var.subscription_id)}/resourceGroups/${local.state_resource_group_name}/providers/Microsoft.Storage/storageAccounts/${local.state_storage_account_name}"
  state_container_id         = "${local.state_storage_account_id}/blobServices/default/containers/tfstate"

  tags = {
    environment = "platform"
    managed-by  = "opentofu"
    owner       = var.owner
    project     = var.project_name
    provider    = "azure"
    root-kind   = "platform"
  }

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
    data_container_id                      = azurerm_storage_container.data.id
    data_uri                               = "${azurerm_storage_account.workload.primary_blob_endpoint}${azurerm_storage_container.data.name}/"
    results_container_id                   = azurerm_storage_container.results.id
    results_container_uri                  = "${azurerm_storage_account.workload.primary_blob_endpoint}${azurerm_storage_container.results.name}"
    control_container_id                   = azurerm_storage_container.control.id
    control_container_uri                  = "${azurerm_storage_account.workload.primary_blob_endpoint}${azurerm_storage_container.control.name}"
    container_registry_id                  = azurerm_container_registry.workload.id
    container_registry_login_server        = azurerm_container_registry.workload.login_server
    runner_subnet_id                       = azurerm_subnet.runner.id
    results_blob_writer_role_definition_id = azurerm_role_definition.blob_create_write_no_delete.role_definition_resource_id
    receipt_publisher_identity_id          = azurerm_user_assigned_identity.receipt_publisher.id
    receipt_publisher_principal_id         = azurerm_user_assigned_identity.receipt_publisher.principal_id
  }
}
