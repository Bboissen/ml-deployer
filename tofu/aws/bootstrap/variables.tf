variable "account_id" {
  description = "Exact 12-digit AWS account ID bound to the reviewed plan."
  type        = string
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be exactly 12 digits."
  }
}

variable "region" {
  description = "AWS V0 region."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.region == "us-east-1"
    error_message = "AWS V0 is fixed to us-east-1 until a reviewed decision changes it."
  }
}

variable "profile" {
  description = "AWS CLI aws login profile used only by the local provider."
  type        = string
  default     = "sposhfi-admin"
}

variable "deployer_role_arn" {
  description = "Optional keyless role assumed through the temporary aws login session."
  type        = string
  default     = ""
}
