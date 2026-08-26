locals {
  resolved_instance_type = var.instance_type_by_profile[var.runner_request.resource_profile]
  expected_backend_key   = "aws/${var.account_scope}/${var.aws_region}/runner/${var.runner_request.deployment_id}.tfstate"
  expected_run_spec_uri  = "s3://${var.results_bucket_name}/run-specs/${var.runner_request.deployment_id}/${var.runner_request.run_spec_sha256}.json"
  data_uri               = "s3://${var.data_bucket_name}/"
  results_uri            = "s3://${var.results_bucket_name}/runs/${var.runner_request.deployment_id}/results/"
  log_uri                = "s3://${var.results_bucket_name}/runs/${var.runner_request.deployment_id}/logs/bootstrap.log"
  local_receipt_key      = "runs/${var.runner_request.deployment_id}/control-input/execution-receipt.local.json"
  receipt_uri            = "s3://${var.results_bucket_name}/control/receipts/${var.runner_request.deployment_id}/completion.v1.json"
  run_spec_key           = "run-specs/${var.runner_request.deployment_id}/${var.runner_request.run_spec_sha256}.json"
  ecr_repository_name    = trimprefix(var.runner_request.oci_repository, "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/")
  request_sha256         = sha256(jsonencode(var.runner_request))
  latest_apply_at_utc    = timeadd(var.started_at_utc, "5m")

  bound_platform_contract = {
    schema_version                   = "1.0.0"
    provider                         = "aws"
    aws_account_id                   = var.aws_account_id
    aws_region                       = var.aws_region
    state_bucket_name                = var.backend_bucket_name
    state_bucket_arn                 = var.state_bucket_arn
    data_bucket_name                 = var.data_bucket_name
    data_bucket_arn                  = var.data_bucket_arn
    results_bucket_name              = var.results_bucket_name
    results_bucket_arn               = var.results_bucket_arn
    runner_subnet_id                 = var.subnet_id
    runner_security_group_id         = var.security_group_id
    ecr_repository_url               = var.runner_request.oci_repository
    ecr_repository_arn               = var.ecr_repository_arn
    runtime_permissions_boundary_arn = var.runtime_permissions_boundary_arn
    receipt_publisher_role_arn       = var.receipt_publisher_role_arn
  }

  platform_contract_sha256 = sha256(jsonencode(var.platform_contract))

  profile_capacity = {
    smoke = {
      vcpu       = 2
      memory_mib = 8192
    }
    balanced = {
      vcpu       = 4
      memory_mib = 16384
    }
    highmem = {
      vcpu       = 4
      memory_mib = 32768
    }
  }
}

resource "aws_instance" "runner" {
  ami                                  = var.ami_id
  instance_type                        = local.resolved_instance_type
  subnet_id                            = var.subnet_id
  vpc_security_group_ids               = [var.security_group_id]
  associate_public_ip_address          = var.associate_public_ipv4_address
  iam_instance_profile                 = aws_iam_instance_profile.runtime.name
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = var.root_volume_size_gib
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region_base64              = base64encode(var.aws_region)
    data_uri_base64                = base64encode(local.data_uri)
    deadline_marker_script_base64  = base64encode(file("${path.module}/../../../shared/bootstrap/deadline-marker.sh"))
    deployment_id_base64           = base64encode(var.runner_request.deployment_id)
    guest_runner_script_base64     = base64encode(file("${path.module}/../../../shared/bootstrap/guest-runner.sh"))
    log_uri_base64                 = base64encode(local.log_uri)
    local_receipt_key_base64       = base64encode(local.local_receipt_key)
    maximum_runtime_minutes_base64 = base64encode(tostring(var.runner_request.maximum_runtime_minutes))
    oci_digest_base64              = base64encode(var.runner_request.oci_digest)
    oci_repository_base64          = base64encode(var.runner_request.oci_repository)
    results_uri_base64             = base64encode(local.results_uri)
    run_spec_bucket_base64         = base64encode(var.results_bucket_name)
    run_spec_key_base64            = base64encode(local.run_spec_key)
    run_spec_object_version_base64 = base64encode(var.runner_request.run_spec_object_version)
    run_spec_sha256_base64         = base64encode(var.runner_request.run_spec_sha256)
    run_spec_uri_base64            = base64encode(var.runner_request.run_spec_uri)
  }))
  user_data_replace_on_change = true

  tags = {
    Name = local.runner_name
  }

  lifecycle {
    precondition {
      condition     = var.backend_key == local.expected_backend_key
      error_message = "backend_key must exactly bind provider, account scope, region and deployment ID."
    }

    precondition {
      condition     = jsonencode(var.platform_contract) == jsonencode(local.bound_platform_contract)
      error_message = "platform_contract must exactly bind the reviewed account, region, storage, network, registry and control identities used by this runner."
    }

    precondition {
      condition     = var.account_scope == var.aws_account_id
      error_message = "AWS account_scope must equal the reviewed 12-digit account ID."
    }

    precondition {
      condition     = var.runner_request.run_spec_uri == local.expected_run_spec_uri
      error_message = "run_spec_uri must exactly match the accepted results bucket, deployment and checksum."
    }

    precondition {
      condition     = startswith(var.runner_request.oci_repository, "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/")
      error_message = "oci_repository must bind the reviewed AWS account and region."
    }

    precondition {
      condition     = var.data_bucket_arn == "arn:${data.aws_partition.current.partition}:s3:::${var.data_bucket_name}" && var.results_bucket_arn == "arn:${data.aws_partition.current.partition}:s3:::${var.results_bucket_name}"
      error_message = "Persistent workload bucket names and ARNs must agree exactly."
    }

    precondition {
      condition     = length(toset([var.state_bucket_arn, var.data_bucket_arn, var.results_bucket_arn])) == 3
      error_message = "State, data and results storage must be three distinct S3 buckets."
    }

    precondition {
      condition     = var.ecr_repository_arn == "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${var.aws_account_id}:repository/${local.ecr_repository_name}"
      error_message = "ECR repository URL and ARN must bind the reviewed account, region and repository."
    }

    precondition {
      condition = (
        startswith(var.runtime_permissions_boundary_arn, "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:policy/") &&
        startswith(var.receipt_publisher_role_arn, "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:role/")
      )
      error_message = "Runtime boundary and receipt publisher must bind the reviewed AWS account."
    }

    precondition {
      condition     = timecmp(var.deadline_utc, local.latest_apply_at_utc) > 0 && timecmp(var.deadline_utc, timeadd(var.started_at_utc, "${var.runner_request.maximum_runtime_minutes}m")) <= 0
      error_message = "deadline_utc must be after the derived five-minute apply window and no later than the accepted maximum runtime from started_at_utc."
    }

    precondition {
      condition     = timecmp(timestamp(), var.started_at_utc) >= 0 && timecmp(timestamp(), local.latest_apply_at_utc) <= 0
      error_message = "The current apply must occur within the reviewed start/latest-apply window; generate and review a fresh plan."
    }
  }
}

resource "aws_scheduler_schedule" "deadline" {
  name                         = "${local.runner_name}-stop"
  description                  = "Absolute UTC provider-side stop for ${var.runner_request.deployment_id}"
  schedule_expression          = "at(${trimsuffix(var.deadline_utc, "Z")})"
  schedule_expression_timezone = "UTC"
  action_after_completion      = "NONE"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.runner.id] })

    retry_policy {
      maximum_event_age_in_seconds = 60
      maximum_retry_attempts       = 3
    }
  }

  lifecycle {
    precondition {
      condition     = timecmp(timestamp(), var.started_at_utc) >= 0 && timecmp(timestamp(), local.latest_apply_at_utc) <= 0
      error_message = "The current apply must occur within the reviewed start/latest-apply window; generate and review a fresh plan."
    }
  }
}
