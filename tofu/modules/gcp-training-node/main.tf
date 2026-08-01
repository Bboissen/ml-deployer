variable "project_id" { type = string }
variable "zone" { type = string }
variable "name" { type = string }
variable "machine_type" { type = string }
variable "provisioning_model" { type = string }
variable "boot_disk_type" { type = string }
variable "boot_disk_size_gb" { type = number }
variable "workspace_disk_enabled" { type = bool }
variable "workspace_disk_type" { type = string }
variable "workspace_disk_size_gb" { type = number }
variable "external_ipv4_enabled" { type = bool }
variable "max_run_duration_seconds" { type = number }
variable "service_account_email" { type = string }
variable "subnetwork_self_link" { type = string }
variable "labels" { type = map(string) }
variable "metadata" { type = map(string) }
variable "startup_script" { type = string }
variable "shutdown_script" { type = string }

resource "google_compute_instance" "this" {
  project                   = var.project_id
  zone                      = var.zone
  name                      = var.name
  machine_type              = var.machine_type
  deletion_protection       = false
  allow_stopping_for_update = false
  labels                    = var.labels
  metadata                  = merge(var.metadata, { startup-script = var.startup_script, shutdown-script = var.shutdown_script })

  boot_disk {
    auto_delete = true
    initialize_params {
      image  = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
      size   = var.boot_disk_size_gb
      type   = var.boot_disk_type
      labels = var.labels
    }
  }

  network_interface {
    subnetwork = var.subnetwork_self_link
    dynamic "access_config" {
      for_each = var.external_ipv4_enabled ? [1] : []
      content {}
    }
  }

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform"]
  }

  scheduling {
    provisioning_model          = var.provisioning_model
    automatic_restart           = false
    on_host_maintenance         = "MIGRATE"
    instance_termination_action = "DELETE"
    max_run_duration {
      seconds = var.max_run_duration_seconds
    }
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    precondition {
      condition     = var.workspace_disk_enabled == false
      error_message = "Workspace disks are disabled until an auto-delete-safe implementation is reviewed."
    }
  }
}

output "instance_name" { value = google_compute_instance.this.name }
output "instance_id" { value = google_compute_instance.this.instance_id }
