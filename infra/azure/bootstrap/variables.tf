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
