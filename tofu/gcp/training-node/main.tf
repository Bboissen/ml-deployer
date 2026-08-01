provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

locals {
  profiles                 = jsondecode(file("${path.module}/../../../configs/gcp/machine_profiles.json"))
  profile                  = local.profiles[var.profile_name]
  max_run_duration_seconds = tonumber(trimsuffix(local.profile.max_run_duration, "s"))
  run_id                   = var.run_id != "" ? var.run_id : "plan-only"
  labels = merge(local.profile.labels, {
    project     = "spotify-ml"
    environment = "training"
    role        = "training"
    run_id      = replace(local.run_id, "_", "-")
    profile     = var.profile_name
    owner       = var.owner_label
    expires_at  = var.expires_at_label
    managed_by  = "opentofu"
  })
}

module "training_node" {
  source                   = "../../modules/gcp-training-node"
  project_id               = var.project_id
  zone                     = var.zone
  name                     = "spotify-ml-${local.run_id}"
  machine_type             = local.profile.machine_type
  provisioning_model       = local.profile.provisioning_model
  boot_disk_type           = local.profile.boot_disk_type
  boot_disk_size_gb        = local.profile.boot_disk_size_gb
  workspace_disk_enabled   = local.profile.workspace_disk_enabled
  workspace_disk_type      = local.profile.workspace_disk_type
  workspace_disk_size_gb   = local.profile.workspace_disk_size_gb
  external_ipv4_enabled    = local.profile.external_ipv4_enabled
  max_run_duration_seconds = local.max_run_duration_seconds
  service_account_email    = var.training_service_account_email
  subnetwork_self_link     = var.subnetwork_self_link
  labels                   = local.labels
  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "TRUE"
    enable-ray             = tostring(local.profile.allow_ray)
    profile                = var.profile_name
    run-id                 = local.run_id
  }
  startup_script  = templatefile("${path.module}/startup.sh.tftpl", { artifact_bucket = var.artifact_bucket_name, run_id = local.run_id, enable_ray = local.profile.allow_ray })
  shutdown_script = templatefile("${path.module}/shutdown.sh.tftpl", { artifact_bucket = var.artifact_bucket_name, run_id = local.run_id })
}

output "instance_name" { value = module.training_node.instance_name }
output "run_id" { value = local.run_id }
