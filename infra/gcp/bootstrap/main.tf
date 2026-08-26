locals {
  create_state_bucket = var.state_bucket_mode == "create"
  common_labels = merge(var.labels, {
    managed_by = "opentofu"
    provider   = "gcp"
    purpose    = "state"
  })
}

resource "google_storage_bucket" "state" {
  count = local.create_state_bucket ? 1 : 0

  name                        = var.state_bucket_name
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.common_labels

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      days_since_noncurrent_time = 90
      with_state                 = "ARCHIVED"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Adoption preparation is intentionally read-only. No import block, state move,
# or ownership assertion exists in this root. A reviewed operator workflow must
# establish state lineage before this candidate can become managed.
data "google_storage_bucket" "adoption_candidate" {
  count = local.create_state_bucket ? 0 : 1

  name = var.state_bucket_name

  lifecycle {
    postcondition {
      condition = (
        self.project == var.project_id &&
        self.uniform_bucket_level_access &&
        self.public_access_prevention == "enforced" &&
        self.versioning[0].enabled
      )
      error_message = "The adoption candidate does not prove the reviewed project, versioning, uniform access, and public-access-prevention controls."
    }
  }
}
