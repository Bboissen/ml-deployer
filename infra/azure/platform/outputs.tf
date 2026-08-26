output "subscription_id" {
  value = var.subscription_id
}

output "location" {
  value = azurerm_resource_group.platform.location
}

output "platform_resource_group_id" {
  value = azurerm_resource_group.platform.id
}

output "state_resource_group_name" {
  value = var.state_resource_group_name
}

output "state_storage_account_name" {
  value = var.state_storage_account_name
}

output "state_container_name" {
  value = var.state_container_name
}

output "state_storage_account_id" {
  value = var.state_storage_account_id
}

output "state_container_id" {
  value = var.state_container_id
}

output "data_container_id" {
  value = azurerm_storage_container.data.id
}

output "data_uri" {
  value = local.platform_interface.data_uri
}

output "results_container_id" {
  value = azurerm_storage_container.results.id
}

output "results_blob_writer_role_definition_id" {
  description = "Platform-owned create/write-no-delete role used by deployment-scoped runner ABAC assignments."
  value       = azurerm_role_definition.blob_create_write_no_delete.role_definition_resource_id
}

output "results_container_uri" {
  value = local.platform_interface.results_container_uri
}

output "control_container_id" {
  value = azurerm_storage_container.control.id
}

output "control_container_uri" {
  value = local.platform_interface.control_container_uri
}

output "container_registry_id" {
  value = azurerm_container_registry.workload.id
}

output "container_registry_login_server" {
  value = azurerm_container_registry.workload.login_server
}

output "runner_subnet_id" {
  value = azurerm_subnet.runner.id
}

output "receipt_publisher_identity_id" {
  value = azurerm_user_assigned_identity.receipt_publisher.id
}

output "receipt_publisher_principal_id" {
  value = azurerm_user_assigned_identity.receipt_publisher.principal_id
}

output "platform_contract_sha256" {
  description = "Canonical SHA-256 binding for the persistent Azure platform interface."
  value       = sha256(jsonencode(local.platform_interface))
}
