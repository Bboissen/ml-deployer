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
variable "admin_email" { type = string }
variable "training_service_account_email" { type = string }
