resource "azurerm_role_assignment" "runtime_data_reader" {
  scope                = var.data_container_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.runtime.principal_id
  principal_type       = "ServicePrincipal"
  description          = "Read and list the accepted generic data container for this one disposable runner identity."
}

resource "azurerm_role_assignment" "runtime_registry_pull" {
  scope                = var.container_registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.runtime.principal_id
  principal_type       = "ServicePrincipal"
  description          = "Pull only from the accepted provider-local registry with this one disposable runner identity."
}

resource "azurerm_role_assignment" "runtime_run_spec_reader" {
  scope                = var.results_container_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.runtime.principal_id
  principal_type       = "ServicePrincipal"
  description          = "Read only the immutable run specification for ${var.runner_request.deployment_id}; list is denied."
  condition_version    = "2.0"
  condition            = <<-EOT
(
  (
    !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'} AND NOT SubOperationMatches{'Blob.List'})
  )
  OR
  (
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals '${local.run_spec_blob_path}'
  )
)
AND
(
  !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'} AND SubOperationMatches{'Blob.List'})
)
EOT
}

resource "azurerm_role_assignment" "runtime_deployment_writer" {
  scope              = var.results_container_id
  role_definition_id = var.results_blob_writer_role_definition_id
  principal_id       = azurerm_user_assigned_identity.runtime.principal_id
  principal_type     = "ServicePrincipal"
  description        = "Create or update only this deployment's logs, results and control-input handoff; no read or delete."
  condition_version  = "2.0"
  condition          = <<-EOT
(
  (
    !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'})
  )
  OR
  (
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals '${local.log_blob_path}'
    OR
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringLike '${local.result_blob_prefix}*'
    OR
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals '${local.handoff_blob_path}'
  )
)
AND
(
  (
    !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action'})
  )
  OR
  (
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals '${local.log_blob_path}'
    OR
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringLike '${local.result_blob_prefix}*'
    OR
    @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals '${local.handoff_blob_path}'
  )
)
EOT
}
