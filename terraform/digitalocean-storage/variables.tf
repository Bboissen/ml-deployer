variable "region" {
  type        = string
  description = "DigitalOcean region for persistent storage and the worker VPC."
  default     = "ams3"

  validation {
    condition     = var.region == "ams3"
    error_message = "region must be exactly ams3."
  }
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique private Spaces bucket name for infrastructure state."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a 3-63 character lowercase DNS-compatible name."
  }
}

variable "bronze_bucket_name" {
  type        = string
  description = "Globally unique private Spaces bucket name for Demo Bronze objects."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bronze_bucket_name))
    error_message = "bronze_bucket_name must be a 3-63 character lowercase DNS-compatible name."
  }
}

variable "vpc_name" {
  type        = string
  description = "Persistent named VPC shared by the storage contract and disposable workers."
  default     = "demo-data-ams3"

  validation {
    condition     = length(trimspace(var.vpc_name)) > 0
    error_message = "vpc_name must not be empty."
  }
}
