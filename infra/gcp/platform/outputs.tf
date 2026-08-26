locals {
  platform_binding = {
    schema_version                          = "1.0.0"
    provider                                = "gcp"
    project_id                              = var.project_id
    region                                  = var.region
    state_bucket_name                       = var.state_bucket_name
    data_bucket_name                        = google_storage_bucket.data.name
    results_bucket_name                     = google_storage_bucket.results.name
    artifact_repository_id                  = google_artifact_registry_repository.runtime.repository_id
    artifact_repository_uri                 = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.runtime.repository_id}"
    network_self_link                       = google_compute_network.runner.self_link
    subnetwork_self_link                    = google_compute_subnetwork.runner.self_link
    receipt_publisher_service_account_email = google_service_account.receipt_publisher.email
    workload_results_prefix                 = "runs/"
    reserved_control_prefix                 = "control/"
    bootstrap_log_suffix                    = "/logs/bootstrap.log"
    local_receipt_handoff_suffix            = "/control-input/execution-receipt.local.json"
    interactive_access_enabled              = var.enable_iap_ssh
  }
  platform_binding_sha256 = sha256(jsonencode(local.platform_binding))
}

output "provider" {
  value = "gcp"
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "data_bucket_name" {
  value = google_storage_bucket.data.name
}

output "data_uri" {
  value = "gs://${google_storage_bucket.data.name}/"
}

output "results_bucket_name" {
  value = google_storage_bucket.results.name
}

output "results_uri" {
  value = "gs://${google_storage_bucket.results.name}/"
}

output "artifact_repository_uri" {
  value = local.platform_binding.artifact_repository_uri
}

output "network_self_link" {
  value = google_compute_network.runner.self_link
}

output "subnetwork_self_link" {
  value = google_compute_subnetwork.runner.self_link
}

output "receipt_publisher_service_account_email" {
  value = google_service_account.receipt_publisher.email
}

output "receipt_control_prefix" {
  value = "gs://${google_storage_bucket.results.name}/control/"
}

output "platform_binding" {
  description = "Closed provider-specific persistent-platform interface consumed as one object by runner states."
  value       = local.platform_binding
}

output "platform_binding_sha256" {
  description = "Deterministic SHA-256 over the exact platform_binding JSON encoding."
  value       = local.platform_binding_sha256
}

output "platform_contract_sha256" {
  description = "Common contract alias of the verified provider-specific platform binding hash."
  value       = local.platform_binding_sha256
}
