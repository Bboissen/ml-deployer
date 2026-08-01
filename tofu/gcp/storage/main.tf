provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  base_labels = {
    project     = "spotify-ml"
    owner       = var.owner_label
    environment = "foundation"
    managed_by  = "opentofu"
  }
  legacy_bucket_roles = toset([
    "roles/storage.legacyBucketOwner",
    "roles/storage.legacyBucketReader",
    "roles/storage.legacyObjectOwner",
    "roles/storage.legacyObjectReader",
  ])
}

module "bronze" {
  source              = "../../modules/gcp-bucket"
  name                = var.bronze_bucket_name
  project_id          = var.project_id
  location            = var.region
  labels              = merge(local.base_labels, { layer = "bronze" })
  versioning_enabled  = true
  soft_delete_seconds = var.soft_delete_seconds
}
module "silver" {
  source              = "../../modules/gcp-bucket"
  name                = var.silver_bucket_name
  project_id          = var.project_id
  location            = var.region
  labels              = merge(local.base_labels, { layer = "silver" })
  versioning_enabled  = var.silver_versioning_enabled
  soft_delete_seconds = var.soft_delete_seconds
}
module "artifacts" {
  source                   = "../../modules/gcp-bucket"
  name                     = var.artifact_bucket_name
  project_id               = var.project_id
  location                 = var.region
  labels                   = merge(local.base_labels, { layer = "artifacts" })
  versioning_enabled       = false
  soft_delete_seconds      = var.soft_delete_seconds
  temporary_lifecycle_days = 7
  temporary_lifecycle_prefixes = [
    "artifacts/tmp/",
    "artifacts/runs/unaccepted/",
  ]
}

resource "google_service_account" "data_publisher" {
  project      = var.project_id
  account_id   = "data-publisher"
  display_name = "Immutable data publisher"
}
resource "google_service_account" "training_runtime" {
  project      = var.project_id
  account_id   = "training-runtime"
  display_name = "Disposable training runtime"
}

resource "google_service_account_iam_member" "admin_impersonates_data_publisher" {
  service_account_id = google_service_account.data_publisher.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.admin_email}"
}
resource "google_service_account_iam_member" "admin_impersonates_training_runtime" {
  service_account_id = google_service_account.training_runtime.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.admin_email}"
}

resource "google_storage_bucket_iam_member" "publisher_bronze_create" {
  bucket = module.bronze.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.data_publisher.email}"
}
resource "google_storage_bucket_iam_member" "publisher_silver_create" {
  bucket = module.silver.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.data_publisher.email}"
}
resource "google_storage_bucket_iam_member" "publisher_bronze_read" {
  bucket = module.bronze.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.data_publisher.email}"
}
resource "google_storage_bucket_iam_member" "publisher_silver_read" {
  bucket = module.silver.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.data_publisher.email}"
}
resource "google_storage_bucket_iam_member" "trainer_bronze_read" {
  bucket = module.bronze.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.training_runtime.email}"
}
resource "google_storage_bucket_iam_member" "trainer_silver_read" {
  bucket = module.silver.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.training_runtime.email}"
}
resource "google_storage_bucket_iam_member" "trainer_artifact_create" {
  bucket = module.artifacts.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.training_runtime.email}"
}

# New GCS buckets grant project basic-role convenience principals legacy
# bucket/object access by default. These role-authoritative empty bindings
# remove only those four legacy grants while preserving all other roles.
resource "google_storage_bucket_iam_binding" "bronze_legacy" {
  for_each = local.legacy_bucket_roles
  bucket   = module.bronze.name
  role     = each.value
  members  = []
}
resource "google_storage_bucket_iam_binding" "silver_legacy" {
  for_each = local.legacy_bucket_roles
  bucket   = module.silver.name
  role     = each.value
  members  = []
}
resource "google_storage_bucket_iam_binding" "artifacts_legacy" {
  for_each = local.legacy_bucket_roles
  bucket   = module.artifacts.name
  role     = each.value
  members  = []
}

output "bronze_bucket_name" { value = module.bronze.name }
output "silver_bucket_name" { value = module.silver.name }
output "artifact_bucket_name" { value = module.artifacts.name }
output "data_publisher_email" { value = google_service_account.data_publisher.email }
output "training_runtime_email" { value = google_service_account.training_runtime.email }
