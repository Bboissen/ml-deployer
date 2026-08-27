resource "azurerm_virtual_network" "platform" {
  name                = "${local.name_prefix}-vnet"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  address_space       = ["10.90.0.0/16"]
  tags                = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_network_security_group" "runner" {
  name                = "${local.name_prefix}-runner-nsg"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tags                = local.tags

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_subnet" "runner" {
  name                 = "runner"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.platform.name
  address_prefixes     = ["10.90.1.0/24"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.platform.name
  virtual_network_name              = azurerm_virtual_network.platform.name
  address_prefixes                  = ["10.90.2.0/24"]
  private_endpoint_network_policies = "Disabled"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                 = "${local.name_prefix}-blob-link"
  private_dns_zone_id  = azurerm_private_dns_zone.blob.id
  virtual_network_id   = azurerm_virtual_network.platform.id
  registration_enabled = false
  tags                 = local.tags

  lifecycle {
    prevent_destroy = true
  }
}
