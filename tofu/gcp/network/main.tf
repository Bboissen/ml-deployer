provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_compute_network" "training" {
  project                 = var.project_id
  name                    = "spotify-ml-training"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  lifecycle { prevent_destroy = true }
}
resource "google_compute_subnetwork" "training" {
  project                  = var.project_id
  name                     = "spotify-ml-training-us-central1"
  region                   = var.region
  network                  = google_compute_network.training.id
  ip_cidr_range            = "10.91.0.0/24"
  private_ip_google_access = true
  lifecycle { prevent_destroy = true }
}
resource "google_compute_firewall" "iap_ssh" {
  project                 = var.project_id
  name                    = "spotify-ml-iap-ssh"
  network                 = google_compute_network.training.name
  direction               = "INGRESS"
  source_ranges           = ["35.235.240.0/20"]
  target_service_accounts = [var.training_service_account_email]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
resource "google_compute_project_metadata_item" "os_login" {
  project = var.project_id
  key     = "enable-oslogin"
  value   = "TRUE"
}
resource "google_project_iam_member" "admin_iap" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "user:${var.admin_email}"
}
resource "google_project_iam_member" "admin_oslogin" {
  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = "user:${var.admin_email}"
}

output "network_self_link" { value = google_compute_network.training.self_link }
output "subnetwork_self_link" { value = google_compute_subnetwork.training.self_link }
