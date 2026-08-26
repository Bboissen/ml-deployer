output "subscription_id" {
  description = "Subscription identifier for the Entra-authenticated backend configuration."
  value       = var.subscription_id
}

output "tenant_id" {
  description = "Tenant identifier for the Entra-authenticated backend configuration."
  value       = var.tenant_id
}

output "location" {
  description = "Azure region containing the state resources."
  value       = azurerm_resource_group.state.location
}

output "state_resource_group_name" {
  description = "Dedicated state resource group name."
  value       = azurerm_resource_group.state.name
}

output "state_resource_group_id" {
  description = "Dedicated state resource group ID."
  value       = azurerm_resource_group.state.id
}

output "state_storage_account_name" {
  description = "Dedicated state storage account name."
  value       = azurerm_storage_account.state.name
}

output "state_storage_account_id" {
  description = "Dedicated state-only storage account resource ID."
  value       = azurerm_storage_account.state.id
}

output "state_container_name" {
  description = "Dedicated Blob container used only for OpenTofu state."
  value       = azurerm_storage_container.state.name
}

output "state_container_id" {
  description = "Dedicated state-only Blob container resource ID."
  value       = azurerm_storage_container.state.id
}

output "backend_authentication" {
  description = "Required backend authentication mode; no storage key or SAS is accepted."
  value       = "Microsoft Entra ID (use_azuread_auth=true)"
}
