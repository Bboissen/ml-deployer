resource "azurerm_storage_account" "workload" {
  name                              = local.storage_account_name
  resource_group_name               = azurerm_resource_group.platform.name
  location                          = azurerm_resource_group.platform.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  account_kind                      = "StorageV2"
  access_tier                       = "Hot"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  public_network_access_enabled     = false
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

    precondition {
      condition = (
        var.state_resource_group_name == local.state_resource_group_name &&
        var.state_storage_account_name == local.state_storage_account_name &&
        var.state_container_name == "tfstate" &&
        lower(var.state_storage_account_id) == lower(local.state_storage_account_id) &&
        lower(var.state_container_id) == lower(local.state_container_id)
      )
      error_message = "State storage inputs must exactly match the accepted bootstrap identity."
    }

    precondition {
      condition     = var.state_storage_account_name != local.storage_account_name && lower(var.state_storage_account_id) != lower("${azurerm_resource_group.platform.id}/providers/Microsoft.Storage/storageAccounts/${local.storage_account_name}")
      error_message = "State storage and workload storage must remain separate Azure storage accounts."
    }
  }
}

resource "azurerm_storage_container" "data" {
  name                  = "data"
  storage_account_id    = azurerm_storage_account.workload.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "results" {
  name                  = "results"
  storage_account_id    = azurerm_storage_account.workload.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "control" {
  name                  = "control"
  storage_account_id    = azurerm_storage_account.workload.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_management_policy" "workload" {
  storage_account_id = azurerm_storage_account.workload.id

  rule {
    name    = "expire-unaccepted-temporary-objects"
    enabled = true

    filters {
      prefix_match = ["results/tmp/", "control/tmp/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 7
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_private_endpoint" "blob" {
  name                = "${local.name_prefix}-blob-pe"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "${local.name_prefix}-blob-connection"
    private_connection_resource_id = azurerm_storage_account.workload.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }

  lifecycle {
    prevent_destroy = true
  }
}
