variable "project_id" {
  type    = string
  default = "example-project"
  validation {
    condition     = var.project_id == "example-project"
    error_message = "project_id is fixed for this implementation."
  }
}
variable "region" {
  type    = string
  default = "us-central1"
  validation {
    condition     = var.region == "us-central1"
    error_message = "region must be us-central1."
  }
}
variable "zone" {
  type    = string
  default = "us-central1-a"
}
variable "state_bucket_name" {
  type    = string
  default = "example-project-tofu-state"
}
variable "admin_email" {
  type     = string
  nullable = false
}
variable "owner_label" {
  type    = string
  default = "bbsn"
}
variable "soft_delete_seconds" {
  type    = number
  default = 604800
  validation {
    condition     = var.soft_delete_seconds >= 604800
    error_message = "state soft delete must be at least seven days."
  }
}
