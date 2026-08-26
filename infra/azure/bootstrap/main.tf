locals {
  project_slug         = replace(var.project_name, "-", "")
  resource_group_name  = "${var.project_name}-azure-state-${var.uniqueness_suffix}"
  storage_account_name = "st${local.project_slug}${var.uniqueness_suffix}"
  container_name       = "tfstate"

  tags = {
    environment = "platform"
    managed-by  = "opentofu"
    owner       = var.owner
    project     = var.project_name
    provider    = "azure"
    root-kind   = "bootstrap"
  }
}

resource "azurerm_resource_group" "state" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_account" "state" {
  name                              = local.storage_account_name
  resource_group_name               = azurerm_resource_group.state.name
  location                          = azurerm_resource_group.state.location
  account_tier                      = "Standard"
  account_replication_type          = "GRS"
  account_kind                      = "StorageV2"
  access_tier                       = "Hot"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  public_network_access_enabled     = true
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  infrastructure_encryption_enabled = true
  tags                              = local.tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "state" {
  name                  = local.container_name
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}
