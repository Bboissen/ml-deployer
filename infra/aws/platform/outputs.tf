locals {
  platform_contract = {
    schema_version                   = "1.0.0"
    provider                         = "aws"
    aws_account_id                   = var.aws_account_id
    aws_region                       = var.aws_region
    state_bucket_name                = trimprefix(var.state_bucket_arn, "arn:${data.aws_partition.current.partition}:s3:::")
    state_bucket_arn                 = var.state_bucket_arn
    data_bucket_name                 = aws_s3_bucket.workload["data"].id
    data_bucket_arn                  = aws_s3_bucket.workload["data"].arn
    results_bucket_name              = aws_s3_bucket.workload["results"].id
    results_bucket_arn               = aws_s3_bucket.workload["results"].arn
    runner_subnet_id                 = aws_subnet.runner.id
    runner_security_group_id         = aws_security_group.runner.id
    ecr_repository_url               = aws_ecr_repository.runner.repository_url
    ecr_repository_arn               = aws_ecr_repository.runner.arn
    runtime_permissions_boundary_arn = aws_iam_policy.runtime_boundary.arn
    receipt_publisher_role_arn       = aws_iam_role.receipt_publisher.arn
  }

  platform_contract_sha256 = sha256(jsonencode(local.platform_contract))
}

output "platform_contract" {
  description = "Closed AWS platform binding consumed by runner roots."
  value       = local.platform_contract
}

output "platform_contract_sha256" {
  description = "Canonical OpenTofu JSON SHA-256 of the closed AWS platform binding."
  value       = local.platform_contract_sha256
}

output "data_bucket_name" {
  description = "Generic initially empty data bucket."
  value       = aws_s3_bucket.workload["data"].id
}

output "data_bucket_arn" {
  description = "Generic data bucket ARN."
  value       = aws_s3_bucket.workload["data"].arn
}

output "data_uri" {
  description = "Provider-local generic data URI."
  value       = "s3://${aws_s3_bucket.workload["data"].id}/"
}

output "results_bucket_name" {
  description = "Results and controlled-receipt bucket name."
  value       = aws_s3_bucket.workload["results"].id
}

output "results_bucket_arn" {
  description = "Results and controlled-receipt bucket ARN."
  value       = aws_s3_bucket.workload["results"].arn
}

output "ecr_repository_url" {
  description = "Provider-local immutable OCI repository without a tag or digest."
  value       = aws_ecr_repository.runner.repository_url
}

output "ecr_repository_arn" {
  description = "Provider-local immutable OCI repository ARN."
  value       = aws_ecr_repository.runner.arn
}

output "runner_subnet_id" {
  description = "Persistent subnet for disposable runners."
  value       = aws_subnet.runner.id
}

output "runner_security_group_id" {
  description = "No-ingress security group for disposable runners."
  value       = aws_security_group.runner.id
}

output "runtime_permissions_boundary_arn" {
  description = "Maximum permissions boundary required by every per-deployment runner role."
  value       = aws_iam_policy.runtime_boundary.arn
}

output "receipt_publisher_role_arn" {
  description = "Distinct control-plane publisher identity unavailable to the runner."
  value       = aws_iam_role.receipt_publisher.arn
}

output "receipt_control_prefix" {
  description = "Reserved non-workload-writable completion-receipt prefix."
  value       = "s3://${aws_s3_bucket.workload["results"].id}/control/receipts/"
}
