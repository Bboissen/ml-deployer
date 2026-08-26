resource "azurerm_user_assigned_identity" "receipt_publisher" {
  name                = "${local.name_prefix}-receipt-publisher"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tags                = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_definition" "blob_create_write_no_delete" {
  name        = "${local.name_prefix}-blob-create-write"
  scope       = azurerm_resource_group.platform.id
  description = "Create and update Blob objects without read, object deletion or container deletion."

  permissions {
    actions     = []
    not_actions = []
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action",
    ]
    not_data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
    ]
  }

  assignable_scopes = [azurerm_resource_group.platform.id]

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "publisher_results_reader" {
  scope                = azurerm_storage_container.results.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.receipt_publisher.principal_id
  principal_type       = "ServicePrincipal"
  description          = "Read exact per-deployment local receipts and bounded bootstrap logs only; listing is denied."
  condition_version    = "2.0"
  condition            = <<-EOT
(
  (
    !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'} AND NOT SubOperationMatches{'Blob.List'})
  )
  OR
  (
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringLike 'runs/*/control-input/execution-receipt.local.json'
    OR
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringLike 'runs/*/logs/bootstrap.log'
  )
)
AND
(
  !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'} AND SubOperationMatches{'Blob.List'})
)
EOT
}

resource "azurerm_role_assignment" "publisher_control_writer" {
  scope              = azurerm_storage_container.control.id
  role_definition_id = azurerm_role_definition.blob_create_write_no_delete.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.receipt_publisher.principal_id
  principal_type     = "ServicePrincipal"
}
