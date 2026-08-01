provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_storage_bucket" "state" {
  name                        = var.state_bucket_name
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels = {
    project     = "spotify-ml"
    environment = "foundation"
    owner       = var.owner_label
    managed_by  = "opentofu"
    data_class  = "tofu-state"
  }
  versioning { enabled = true }
  soft_delete_policy { retention_duration_seconds = var.soft_delete_seconds }
  lifecycle { prevent_destroy = true }
}

resource "google_service_account" "tofu_deployer" {
  project      = var.project_id
  account_id   = "tofu-deployer"
  display_name = "OpenTofu deployer (impersonation only)"
}

resource "google_service_account_iam_member" "admin_token_creator" {
  service_account_id = google_service_account.tofu_deployer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.admin_email}"
}

resource "google_storage_bucket_iam_member" "state_object_admin" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.tofu_deployer.email}"
}

locals {
  deployer_roles = toset([
    "roles/compute.instanceAdmin.v1",
    "roles/compute.networkAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/storage.admin",
  ])
}

resource "google_project_iam_member" "deployer" {
  for_each = local.deployer_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.tofu_deployer.email}"
}

output "state_bucket_name" { value = google_storage_bucket.state.name }
output "tofu_deployer_email" { value = google_service_account.tofu_deployer.email }
