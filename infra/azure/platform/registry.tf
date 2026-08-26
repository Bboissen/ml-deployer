resource "azurerm_container_registry" "workload" {
  name                          = local.registry_name
  resource_group_name           = azurerm_resource_group.platform.name
  location                      = azurerm_resource_group.platform.location
  sku                           = "Basic"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = true
  tags                          = local.tags

  lifecycle {
    prevent_destroy = true
  }
}
