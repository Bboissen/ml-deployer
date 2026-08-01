variable "name" { type = string }
variable "project_id" { type = string }
variable "location" { type = string }
variable "labels" { type = map(string) }
variable "versioning_enabled" { type = bool }
variable "soft_delete_seconds" { type = number }
variable "temporary_lifecycle_days" {
  type    = number
  default = 0
}
variable "temporary_lifecycle_prefixes" {
  type    = list(string)
  default = []
}

resource "google_storage_bucket" "this" {
  name                        = var.name
  project                     = var.project_id
  location                    = var.location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = var.labels

  versioning {
    enabled = var.versioning_enabled
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_seconds
  }

  dynamic "lifecycle_rule" {
    for_each = var.temporary_lifecycle_days > 0 ? [1] : []
    content {
      condition {
        matches_prefix = var.temporary_lifecycle_prefixes
        age            = var.temporary_lifecycle_days
      }
      action { type = "Delete" }
    }
  }

  lifecycle { prevent_destroy = true }
}

output "name" { value = google_storage_bucket.this.name }
