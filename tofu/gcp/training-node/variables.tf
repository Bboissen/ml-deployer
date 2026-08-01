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
variable "zone" {
  type    = string
  default = "us-central1-a"
}
variable "profile_name" {
  type    = string
  default = "smoke-free"
  validation {
    condition     = contains(["smoke-free", "smoke-paid", "dev-memory"], var.profile_name)
    error_message = "profile is not allowlisted."
  }
}
variable "run_id" {
  type    = string
  default = ""
}
variable "expires_at_label" {
  type    = string
  default = "plan-only"
}
variable "owner_label" {
  type    = string
  default = "bbsn"
}
variable "training_service_account_email" { type = string }
variable "subnetwork_self_link" { type = string }
variable "artifact_bucket_name" {
  type    = string
  default = "example-project-artifacts"
}
