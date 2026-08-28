variable "subscription_id" {
  description = "Azure subscription UUID. This is an identifier, not a credential."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription UUID."
  }
}

variable "tenant_id" {
  description = "Microsoft Entra tenant UUID. This is an identifier, not a credential."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a Microsoft Entra tenant UUID."
  }
}

variable "location" {
  description = "Azure region selected after the read-only quota and policy probe."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "location must be a lower-case Azure region identifier such as westeurope."
  }
}

variable "project_name" {
  description = "Short lower-case project name used in Azure resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,11}$", var.project_name))
    error_message = "project_name must be 3-12 lower-case letters, digits or hyphens, starting with a letter."
  }
}

variable "uniqueness_suffix" {
  description = "Reviewed six-character lower-case alphanumeric suffix for runner names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{6}$", var.uniqueness_suffix))
    error_message = "uniqueness_suffix must be exactly six lower-case alphanumeric characters."
  }
}

variable "owner" {
  description = "Non-secret owner label."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{1,62}$", var.owner))
    error_message = "owner must be a bounded non-secret label."
  }
}

variable "runner_request" {
  description = "Closed frozen Goal 02 request for exactly one Azure runner state."
  type        = any

  validation {
    condition = try(
      length(keys(var.runner_request)) == 11 &&
      length(setsubtract(toset(keys(var.runner_request)), toset([
        "schema_version",
        "deployment_id",
        "provider",
        "oci_repository",
        "oci_digest",
        "run_spec_uri",
        "run_spec_sha256",
        "run_spec_object_version",
        "resource_profile",
        "capacity_mode",
        "maximum_runtime_minutes",
      ]))) == 0,
      false,
    )
    error_message = "runner_request must contain exactly the eleven frozen Goal 02 fields and no unknown attributes."
  }

  validation {
    condition     = var.runner_request.schema_version == "1.0.0"
    error_message = "runner_request.schema_version must be 1.0.0."
  }

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$", var.runner_request.deployment_id))
    error_message = "runner_request.deployment_id must be 3-48 lower-case letters, digits or internal hyphens."
  }

  validation {
    condition     = var.runner_request.provider == "azure"
    error_message = "runner_request.provider must be azure."
  }

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}\\.azurecr\\.io/[a-z0-9]+([._-][a-z0-9]+)*$", var.runner_request.oci_repository))
    error_message = "runner_request.oci_repository must be one lower-case Azure Container Registry repository without a tag or digest."
  }

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.runner_request.oci_digest))
    error_message = "runner_request.oci_digest must be sha256 followed by 64 lower-case hexadecimal characters."
  }

  validation {
    condition     = can(regex("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/[^?#[:space:]]+/run-specs/[a-z0-9][a-z0-9-]{1,46}[a-z0-9]/[0-9a-f]{64}\\.json$", var.runner_request.run_spec_uri))
    error_message = "runner_request.run_spec_uri must be an unsigned content-addressed Azure Blob URI."
  }

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.runner_request.run_spec_sha256))
    error_message = "runner_request.run_spec_sha256 must be 64 lower-case hexadecimal characters."
  }

  validation {
    condition     = can(regex("^[^[:space:][:cntrl:]]{1,512}$", var.runner_request.run_spec_object_version))
    error_message = "runner_request.run_spec_object_version must be a bounded non-empty value without whitespace or controls."
  }

  validation {
    condition     = contains(["smoke", "balanced", "highmem"], var.runner_request.resource_profile)
    error_message = "runner_request.resource_profile must be smoke, balanced or highmem."
  }

  validation {
    condition     = var.runner_request.capacity_mode == "standard"
    error_message = "runner_request.capacity_mode must remain standard until checkpoint recovery is accepted."
  }

  validation {
    condition     = var.runner_request.maximum_runtime_minutes == floor(var.runner_request.maximum_runtime_minutes) && var.runner_request.maximum_runtime_minutes >= 15 && var.runner_request.maximum_runtime_minutes <= 720
    error_message = "runner_request.maximum_runtime_minutes must be an integer from 15 through 720."
  }
}

variable "started_at_utc" {
  description = "Reviewed planned runner start in whole-minute RFC3339 UTC form."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00Z$", var.started_at_utc)) && can(formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", var.started_at_utc))
    error_message = "started_at_utc must be a valid whole-minute UTC timestamp."
  }
}

variable "deadline_utc" {
  description = "Reviewed absolute UTC provider deadline in RFC3339 Z form."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00Z$", var.deadline_utc)) && can(formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", var.deadline_utc))
    error_message = "deadline_utc must be a valid whole-minute UTC timestamp such as 2026-08-26T12:00:00Z."
  }
}

variable "account_scope" {
  description = "Non-secret Azure subscription scope used in the deterministic runner backend key."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.account_scope))
    error_message = "account_scope must be a lower-case Azure subscription UUID."
  }
}

variable "backend_key" {
  description = "Reviewed deterministic remote-state key for exactly one Azure deployment."
  type        = string

  validation {
    condition     = can(regex("^azure/[0-9a-f-]{36}/[a-z0-9]+/runner/[a-z0-9][a-z0-9-]{1,46}[a-z0-9]\\.tfstate$", var.backend_key))
    error_message = "backend_key must be a deterministic Azure per-deployment runner key."
  }
}

variable "state_resource_group_name" {
  description = "Accepted bootstrap state resource group name used by external backend configuration."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._()-]{1,90}$", var.state_resource_group_name))
    error_message = "state_resource_group_name must be a bounded Azure resource group name."
  }
}

variable "state_storage_account_name" {
  description = "Accepted dedicated state storage account name used by external backend configuration."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.state_storage_account_name))
    error_message = "state_storage_account_name must be an Azure storage account name."
  }
}

variable "state_container_name" {
  description = "Accepted dedicated state container name used by external backend configuration."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$", var.state_container_name))
    error_message = "state_container_name must be a conservative Azure container name."
  }
}

variable "state_storage_account_id" {
  description = "Accepted dedicated state storage account resource ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Storage/storageAccounts/[a-z0-9]{3,24}$", var.state_storage_account_id))
    error_message = "state_storage_account_id must be an Azure storage account resource ID."
  }
}

variable "state_container_id" {
  description = "Accepted dedicated state Blob container resource ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Storage/storageAccounts/[a-z0-9]{3,24}/blobServices/default/containers/[a-z0-9-]+$", var.state_container_id))
    error_message = "state_container_id must be an Azure Blob container resource ID."
  }
}

variable "platform_contract_sha256" {
  description = "Accepted persistent-platform interface checksum."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.platform_contract_sha256))
    error_message = "platform_contract_sha256 must be 64 lower-case hexadecimal characters."
  }
}

variable "subnet_id" {
  description = "Persistent platform runner subnet resource ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/runner$", var.subnet_id))
    error_message = "subnet_id must identify the persistent Azure runner subnet."
  }
}

variable "receipt_publisher_identity_id" {
  description = "Persistent control-plane publisher identity ID used only to bind the accepted platform interface; it is never attached to the VM."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", var.receipt_publisher_identity_id))
    error_message = "receipt_publisher_identity_id must be an Azure user-assigned identity resource ID."
  }
}

variable "receipt_publisher_principal_id" {
  description = "Principal UUID of the persistent receipt publisher, used only in the accepted platform checksum."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.receipt_publisher_principal_id))
    error_message = "receipt_publisher_principal_id must be a UUID."
  }
}

variable "data_container_id" {
  description = "Persistent platform data container resource ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Storage/storageAccounts/[a-z0-9]{3,24}/blobServices/default/containers/data$", var.data_container_id))
    error_message = "data_container_id must identify the persistent Azure data container."
  }
}

variable "results_container_id" {
  description = "Persistent platform results container resource ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Storage/storageAccounts/[a-z0-9]{3,24}/blobServices/default/containers/results$", var.results_container_id))
    error_message = "results_container_id must identify the persistent Azure results container."
  }
}

variable "control_container_id" {
  description = "Persistent platform control container resource ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Storage/storageAccounts/[a-z0-9]{3,24}/blobServices/default/containers/control$", var.control_container_id))
    error_message = "control_container_id must identify the persistent Azure control container."
  }
}

variable "results_blob_writer_role_definition_id" {
  description = "Platform-owned create/write-no-delete Blob role definition resource ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}(?:/resourceGroups/[^/]+)?/providers/Microsoft\\.Authorization/roleDefinitions/[0-9a-fA-F-]{36}$", var.results_blob_writer_role_definition_id))
    error_message = "results_blob_writer_role_definition_id must be the platform custom role resource ID."
  }
}

variable "container_registry_id" {
  description = "Persistent platform Azure Container Registry resource ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.ContainerRegistry/registries/[a-z0-9]{5,50}$", var.container_registry_id))
    error_message = "container_registry_id must identify the persistent Azure Container Registry."
  }
}

variable "container_registry_login_server" {
  description = "Persistent platform ACR login server without a repository path."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}\\.azurecr\\.io$", var.container_registry_login_server))
    error_message = "container_registry_login_server must be one Azure Container Registry login server."
  }
}

variable "data_uri" {
  description = "Private provider-local data container URI. It is initially empty."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/data/$", var.data_uri))
    error_message = "data_uri must identify the private Azure data container and end in a slash."
  }
}

variable "results_container_uri" {
  description = "Private provider-local results container URI without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/results$", var.results_container_uri))
    error_message = "results_container_uri must identify the private Azure results container."
  }
}

variable "control_container_uri" {
  description = "Reserved provider control container URI without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/control$", var.control_container_uri))
    error_message = "control_container_uri must identify the reserved Azure control container."
  }
}

variable "source_image_id" {
  description = "Immutable Azure Compute Gallery image-version resource ID prepared with Docker, Azure CLI and jq."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Compute/galleries/[^/]+/images/[^/]+/versions/[^/]+$", var.source_image_id))
    error_message = "source_image_id must identify an immutable Azure Compute Gallery image version."
  }
}

variable "admin_username" {
  description = "Local VM administrator account used only through Azure Run Command."
  type        = string
  default     = "mlrunner"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{2,30}$", var.admin_username))
    error_message = "admin_username must be a conservative Linux account name."
  }
}

variable "admin_ssh_public_key" {
  description = "Public SSH key required by Azure; the runner has no inbound network rule and is managed through provider-native tooling."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+={0,3}( [^\\r\\n]+)?$", var.admin_ssh_public_key))
    error_message = "admin_ssh_public_key must be one OpenSSH public key, never a private key."
  }
}
