output "state_bucket_name" {
  description = "Reviewed state bucket name; adopt_managed remains read-only until a separate import approval."
  value       = var.state_bucket_name
}

output "state_bucket_uri" {
  description = "GCS URI reserved exclusively for OpenTofu state."
  value       = "gs://${var.state_bucket_name}"
}

output "state_bucket_mode" {
  description = "Explicit create or adoption-preparation mode."
  value       = var.state_bucket_mode
}

output "backend_prefix_root" {
  description = "Provider/project/region namespace used by later GCS backend configurations."
  value       = "gcp/${var.project_id}/${var.region}"
}

output "adoption_requires_separate_authorization" {
  description = "True when this root only inspected an adoption candidate and changed no ownership or state."
  value       = var.state_bucket_mode == "adopt_managed"
}
