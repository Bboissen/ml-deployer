output "state_bucket_name" {
  description = "Dedicated state-only S3 bucket name."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "Dedicated state-only S3 bucket ARN."
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "Reviewed backend region."
  value       = var.aws_region
}

output "backend_locking" {
  description = "Required native OpenTofu S3 lock-file setting."
  value       = "use_lockfile=true"
}
