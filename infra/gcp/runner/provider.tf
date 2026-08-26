provider "google" {
  project = var.platform_binding.project_id
  region  = var.platform_binding.region
  zone    = var.zone
}
