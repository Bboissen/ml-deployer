variable "project_id" {
  type    = string
  default = "example-project"
  validation {
    condition     = var.project_id == "example-project"
    error_message = "project_id is fixed."
  }
}
variable "region" {
  type    = string
  default = "us-central1"
  validation {
    condition     = var.region == "us-central1"
    error_message = "region is fixed."
  }
}
variable "bronze_bucket_name" {
  type    = string
  default = "example-project-bronze"
}
variable "silver_bucket_name" {
  type    = string
  default = "example-project-silver"
}
variable "artifact_bucket_name" {
  type    = string
  default = "example-project-artifacts"
}
variable "admin_email" {
  type     = string
  nullable = false
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.admin_email))
    error_message = "admin_email must be a valid user email address."
  }
}
variable "silver_versioning_enabled" {
  type    = bool
  default = false
}
variable "soft_delete_seconds" {
  type    = number
  default = 604800
}
variable "owner_label" {
  type    = string
  default = "bbsn"
}
