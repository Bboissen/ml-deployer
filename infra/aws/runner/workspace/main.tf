resource "aws_scheduler_schedule" "workspace_deadline" {
  name                         = local.deadline_name
  group_name                   = "default"
  schedule_expression          = "at(${trimsuffix(local.terminate_at, "Z")})"
  schedule_expression_timezone = "UTC"
  state                        = "ENABLED"
  action_after_completion      = "NONE"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = var.guard.function_arn
    role_arn = var.guard.invoker_role_arn
    input    = jsonencode({ kind = "lease", guard_id = var.guard.guard_id, workspace_id = local.id, lease_id = var.lease.id })
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 3
    }
    dead_letter_config { arn = var.guard.failure_queue_arn }
  }
  depends_on = [terraform_data.lease]
}

resource "aws_iam_role" "launch" {
  permissions_boundary = "arn:aws:iam::${var.aws_account_id}:policy/${var.resource_prefix}-workspace-launch-boundary"
  name                 = "${local.role_name}-launch"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { AWS = var.deployer_role_arn }
  }] })
  depends_on = [aws_scheduler_schedule.workspace_deadline, aws_iam_instance_profile.workspace]
}

resource "aws_iam_role_policy" "launch" {
  name = "immutable-lease-launch"
  role = aws_iam_role.launch.name
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(var.phase == "retire" ? [{ Effect = "Deny", Action = "ec2:RunInstances", Resource = "*" }] : [], [
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", Condition = { ArnNotEquals = { "ec2:InstanceProfile" = "arn:aws:iam::${var.aws_account_id}:instance-profile/${local.role_name}" } } },
    { Effect = "Allow", Action = ["ec2:Describe*", "iam:GetUserPolicy", "iam:ListUserTags", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:GetInstanceProfile", "iam:ListInstanceProfilesForRole", "scheduler:GetSchedule", "ssm:GetDocument", "ssm:DescribeDocument", "ssm:ListTagsForResource"], Resource = "*" },
    { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = var.state_bucket_arn },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${var.state_bucket_arn}/aws/${var.aws_account_id}/${var.aws_region}/runner/${local.id}.tfstate", "${var.state_bucket_arn}/aws/${var.aws_account_id}/${var.aws_region}/runner/${local.id}.tfstate.tflock"] },
    { Effect = "Allow", Action = "iam:PassRole", Resource = aws_iam_role.workspace[local.id].arn, Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } } },
    {
      Effect = "Allow", Action = "ec2:RunInstances", Resource = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:volume/*"],
      Condition = {
        StringEquals          = { for k, v in local.guard_tags : "aws:RequestTag/${k}" => v },
        DateGreaterThanEquals = { "aws:CurrentTime" = var.lease.starts_at }, DateLessThanEquals = { "aws:CurrentTime" = var.lease.launch_before }
      }
    },
    {
      Effect    = "Allow", Action = "ec2:RunInstances",
      Resource  = ["arn:aws:ec2:${var.aws_region}::image/${var.ami_id}", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:subnet/${var.subnet_id}", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group/${var.security_group_id}", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:network-interface/*"],
      Condition = { DateGreaterThanEquals = { "aws:CurrentTime" = var.lease.starts_at }, DateLessThanEquals = { "aws:CurrentTime" = var.lease.launch_before } }
    },
    {
      Effect    = "Allow", Action = "ec2:CreateTags", Resource = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:volume/*"],
      Condition = { StringEquals = { "ec2:CreateAction" = "RunInstances" } }
    },
    { Effect = "Deny", Action = ["iam:Create*", "iam:Delete*", "iam:Put*", "iam:Attach*", "iam:Detach*", "iam:Update*", "iam:Tag*", "iam:Untag*", "scheduler:Create*", "scheduler:Update*", "scheduler:Delete*", "ec2:Modify*", "ec2:StartInstances", "ec2:DeleteTags"], Resource = "*" }
  ]) })
}

resource "aws_ssm_document" "terminal" {
  name            = local.terminal_document_name
  document_type   = "Session"
  document_format = "JSON"
  content = jsonencode({ schemaVersion = "1.0", sessionType = "Standard_Stream", inputs = {
    s3BucketName           = "", s3KeyPrefix = "", s3EncryptionEnabled = true,
    cloudWatchLogGroupName = "", cloudWatchEncryptionEnabled = true, cloudWatchStreamingEnabled = false,
    kmsKeyId               = "", runAsEnabled = true, runAsDefaultUser = "workspace",
    idleSessionTimeout     = "20", maxSessionDuration = "60", shellProfile = { linux = "export HOME=/home/workspace; cd /workspaces/${local.id}; exec /bin/bash -l", windows = "" }
  } })
}

resource "aws_instance" "workspace" {
  key_name                             = ""
  count                                = var.phase == "launch" ? 1 : 0
  ami                                  = var.ami_id
  instance_type                        = var.instance_type
  subnet_id                            = var.subnet_id
  vpc_security_group_ids               = [var.security_group_id]
  associate_public_ip_address          = true
  iam_instance_profile                 = aws_iam_instance_profile.workspace[local.id].name
  disable_api_termination              = false
  disable_api_stop                     = false
  instance_initiated_shutdown_behavior = "terminate"
  tags                                 = local.guard_tags
  volume_tags                          = local.guard_tags
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }
  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
  user_data_base64 = base64gzip(templatefile("${path.module}/user-data.sh.tftpl", {
    workspace_id       = local.id, toolbox_zip_base64 = filebase64(var.toolbox_zip_path),
    toolbox_zip_sha256 = var.toolbox_zip_sha256, region = var.aws_region
  }))
  depends_on = [aws_scheduler_schedule.workspace_deadline, aws_iam_role_policy.launch, aws_iam_instance_profile.workspace, aws_ssm_document.terminal, aws_iam_user_policy.operator]
  lifecycle {
    precondition {
      condition = try(var.guard_observation.guard_id == var.guard.guard_id &&
        var.guard_observation.code_sha256 == var.guard.code_sha256 &&
        var.guard_observation.recurrence_enabled && var.guard_observation.deadline_enabled &&
        var.guard_observation.iam_verified && var.guard_observation.alarms_ok &&
        timecmp(timestamp(), var.guard_observation.observed_at) >= 0 &&
        timecmp(timestamp(), timeadd(var.guard_observation.observed_at, "120s")) <= 0 &&
        timecmp(timestamp(), var.guard_observation.heartbeat_at) >= 0 &&
        timecmp(timestamp(), timeadd(var.guard_observation.heartbeat_at, "120s")) <= 0,
      false)
      error_message = "Launch requires fresh matching native guard/deadline/IAM/heartbeat/alarm readback."
    }
    precondition {
      condition     = timecmp(timestamp(), var.lease.starts_at) >= 0 && timecmp(timestamp(), var.lease.launch_before) <= 0
      error_message = "Launch lease is not open; review a fresh lease/plan instead of extending it."
    }
    precondition {
      condition     = filesha256(var.toolbox_zip_path) == var.toolbox_zip_sha256
      error_message = "Toolbox artifact differs from its reviewed hash."
    }
  }
}

output "workspace_preparation" {
  value = {
    launch_role_arn          = local.launch_role_arn, deadline_name = local.deadline_name,
    profile                  = aws_iam_instance_profile.workspace[local.id].name,
    terminal_document        = aws_ssm_document.terminal.name,
    terminal_document_sha256 = sha256(aws_ssm_document.terminal.content),
    role_arn                 = aws_iam_role.workspace[local.id].arn,
    lease                    = var.lease, guard = var.guard,
    instance_id              = try(aws_instance.workspace[0].id, null), compute_ready = false
  }
}
