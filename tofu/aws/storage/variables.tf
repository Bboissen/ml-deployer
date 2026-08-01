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
  type    = string
  default = "us-east-1"
  validation {
    condition     = var.region == "us-east-1"
    error_message = "AWS V0 is fixed to us-east-1."
  }
}
