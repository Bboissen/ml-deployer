output "deployment_id" {
  value = var.runner_request.deployment_id
}

output "provider" {
  value = var.runner_request.provider
}

output "runner_id" {
  value = aws_instance.runner.id
}

output "workload_identity" {
  value = aws_iam_role.runtime.arn
}

output "resolved_profile" {
  value = {
    requested          = var.runner_request.resource_profile
    provider_sku       = local.resolved_instance_type
    minimum_vcpu       = local.profile_capacity[var.runner_request.resource_profile].vcpu
    minimum_memory_mib = local.profile_capacity[var.runner_request.resource_profile].memory_mib
  }
}

output "deadline" {
  value = var.deadline_utc
}

output "latest_apply_at_utc" {
  description = "Derived boundary exactly five minutes after the reviewed earliest apply timestamp."
  value       = local.latest_apply_at_utc
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

output "local_execution_receipt_handoff_uri" {
  description = "Create-only workload handoff read by the distinct receipt publisher; never final control evidence."
  value       = "s3://${var.results_bucket_name}/${local.local_receipt_key}"
}

output "request_sha256" {
  value = local.request_sha256
}

output "platform_contract_sha256" {
  value = local.platform_contract_sha256
}

output "backend_binding" {
  description = "Expected external S3 backend binding; backend configuration remains separately reviewed."
  value = {
    bucket       = var.backend_bucket_name
    key          = var.backend_key
    region       = var.aws_region
    use_lockfile = true
  }
}

output "management_hint" {
  value = "aws ssm describe-instance-information --filters Key=InstanceIds,Values=${aws_instance.runner.id} --region ${var.aws_region}"
}

output "provider_deadline_control" {
  value = aws_scheduler_schedule.deadline.arn
}
