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
  description = "Reviewed six-character lower-case alphanumeric suffix for globally unique names."
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

variable "state_resource_group_name" {
  description = "Accepted bootstrap state resource group name."
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
