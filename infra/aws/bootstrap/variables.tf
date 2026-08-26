variable "aws_region" {
  description = "Reviewed AWS region for the state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a conservative AWS region identifier."
  }
}

variable "aws_account_id" {
  description = "Expected AWS account ID; provider operations fail closed in any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "project_name" {
  description = "Short lower-case project identifier used in tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 lower-case letters, digits or internal hyphens."
  }
}

variable "state_bucket_name" {
  description = "Globally unique reviewed name for the dedicated state-only S3 bucket."
  type        = string

  validation {
    condition = (
      length(var.state_bucket_name) >= 3 &&
      length(var.state_bucket_name) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.state_bucket_name)) &&
      !strcontains(var.state_bucket_name, "..")
    )
    error_message = "state_bucket_name must be a conservative private S3 bucket name."
  }
}

variable "tags" {
  description = "Additional non-secret ownership and cost-allocation tags."
  type        = map(string)
  default     = {}
}
