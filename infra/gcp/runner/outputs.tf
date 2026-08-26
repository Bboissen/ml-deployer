output "deployment_id" {
  value = var.runner_request.deployment_id
}

output "provider" {
  value = "gcp"
}

output "runner_id" {
  value = google_compute_instance.runner.id
}

output "absolute_delete_job" {
  value = google_cloud_scheduler_job.absolute_delete.id
}

output "deadline_identity" {
  value = google_service_account.deadline_deleter.email
}

output "workload_identity" {
  value = google_service_account.workload.email
}

output "resolved_profile" {
  value = {
    requested          = var.runner_request.resource_profile
    machine_type       = var.machine_types[var.runner_request.resource_profile]
    minimum_vcpu       = local.profile_capacity[var.runner_request.resource_profile].minimum_vcpu
    minimum_memory_mib = local.profile_capacity[var.runner_request.resource_profile].minimum_memory_mib
  }
}

output "deadline" {
  description = "Reviewed absolute UTC upper bound; native max_run_duration and the independent Scheduler DELETE are both retained."
  value       = var.deadline_utc
}

output "earliest_apply_at_utc" {
  value = var.started_at_utc
}

output "latest_apply_at_utc" {
  value = local.latest_apply_at_utc
}

output "data_uri" {
  value = local.data_uri
}

output "results_uri" {
  value = local.results_uri
}

output "receipt_uri" {
  value = local.receipt_uri
}

output "request_sha256" {
  value = local.request_sha256
}

output "platform_binding_sha256" {
  description = "Digest recomputed by the runner from the exact consumed platform_binding object."
  value       = local.platform_binding_sha256
}

output "platform_contract_sha256" {
  description = "Common contract alias of the runner-verified provider-specific platform binding hash."
  value       = local.platform_binding_sha256
}

output "runner_backend_key" {
  value = local.runner_backend_key
}

output "management_hint" {
  description = "Read-only native observation command; it does not authorize login, restart, or deletion."
  value       = "gcloud compute instances describe ${google_compute_instance.runner.name} --project=${local.platform_binding.project_id} --zone=${var.zone} --format=json"
}
