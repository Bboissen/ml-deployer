variable "workspace_guard" {
  description = "Reviewed deterministic watchdog ZIP and existing SNS alarm destination; null retains the historical platform without enabling workspace launch."
  type = object({
    zip_path        = string
    zip_sha256      = string
    alarm_topic_arn = string
  })
  default = null
  validation {
    condition = var.workspace_guard == null ? true : (
      can(regex("^[0-9a-f]{64}$", var.workspace_guard.zip_sha256)) &&
      can(regex("^arn:aws:sns:${var.aws_region}:${var.aws_account_id}:[A-Za-z0-9_-]+$", var.workspace_guard.alarm_topic_arn))
    )
    error_message = "Guard requires an exact ZIP SHA256 and reviewed same-account/region SNS alarm destination."
  }
}

locals {
  workspace_guards = var.workspace_guard == null ? {} : { active = var.workspace_guard }
  guard_name       = "${var.resource_prefix}-workspace-watchdog"
  guard_id         = substr(sha256("${var.aws_account_id}/${var.aws_region}/${var.resource_prefix}/workspace-v1"), 0, 32)
}

resource "aws_cloudwatch_log_group" "workspace_guard" {
  for_each          = local.workspace_guards
  name              = "/aws/lambda/${local.guard_name}"
  retention_in_days = 30
  lifecycle { prevent_destroy = true }
}

resource "aws_sqs_queue" "workspace_guard_failures" {
  for_each                  = local.workspace_guards
  name                      = "${local.guard_name}-failures"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_role" "workspace_guard" {
  for_each = local.workspace_guards
  name     = local.guard_name
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" }
  }] })
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_role_policy" "workspace_guard" {
  lifecycle { prevent_destroy = true }
  for_each = local.workspace_guards
  role     = aws_iam_role.workspace_guard[each.key].name
  name     = "guard-owned-termination-only"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "ec2:DescribeInstances", Resource = "*" },
    {
      Effect   = "Allow", Action = "ec2:TerminateInstances",
      Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*",
      Condition = { StringEquals = {
        "ec2:ResourceTag/GuardId" = local.guard_id, "ec2:ResourceTag/ManagedBy" = "opentofu",
        "ec2:ResourceTag/Project" = var.project_name, "ec2:ResourceTag/Root" = "runner"
      } }
    },
    {
      Effect   = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"],
      Resource = "${trimsuffix(aws_cloudwatch_log_group.workspace_guard[each.key].arn, ":*")}:*"
    },
    { Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.workspace_guard_failures[each.key].arn },
    # Preserve AWS-managed Lambda environment-key grants; do not grant KMS administration.
    { Effect = "Deny", NotAction = ["ec2:DescribeInstances", "ec2:TerminateInstances", "logs:CreateLogStream", "logs:PutLogEvents", "sqs:SendMessage", "kms:Decrypt"], Resource = "*" }
  ] })
}

resource "aws_lambda_function" "workspace_guard" {
  for_each         = local.workspace_guards
  function_name    = local.guard_name
  role             = aws_iam_role.workspace_guard[each.key].arn
  filename         = each.value.zip_path
  source_code_hash = filebase64sha256(each.value.zip_path)
  runtime          = "python3.13"
  handler          = "watchdog.handler"
  architectures    = ["x86_64"]
  timeout          = 30
  memory_size      = 256
  publish          = true
  # Restricted account: use its observed unreserved pool; never increase quotas.
  reserved_concurrent_executions = -1
  environment {
    variables = {
      GUARD_ID   = local.guard_id, OWNER_PROJECT = var.project_name,
      ACCOUNT_ID = var.aws_account_id, CODE_SHA256 = each.value.zip_sha256
    }
  }
  depends_on = [aws_iam_role_policy.workspace_guard, aws_cloudwatch_log_group.workspace_guard]
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = filesha256(each.value.zip_path) == each.value.zip_sha256
      error_message = "Guard ZIP differs from its immutable reviewed artifact."
    }
  }
}

resource "aws_lambda_function_event_invoke_config" "workspace_guard" {
  for_each                     = local.workspace_guards
  function_name                = aws_lambda_function.workspace_guard[each.key].function_name
  qualifier                    = aws_lambda_function.workspace_guard[each.key].version
  maximum_event_age_in_seconds = 300
  maximum_retry_attempts       = 2
  destination_config {
    on_failure { destination = aws_sqs_queue.workspace_guard_failures[each.key].arn }
  }
  depends_on = [aws_iam_role_policy.workspace_guard]
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_role" "workspace_guard_invoker" {
  for_each = local.workspace_guards
  name     = "${local.guard_name}-invoke"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "scheduler.amazonaws.com" },
    Condition = {
      StringEquals = { "aws:SourceAccount" = var.aws_account_id },
      ArnEquals    = { "aws:SourceArn" = "arn:aws:scheduler:${var.aws_region}:${var.aws_account_id}:schedule-group/default" }
    }
  }] })
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_role_policy" "workspace_guard_invoker" {
  for_each = local.workspace_guards
  role     = aws_iam_role.workspace_guard_invoker[each.key].name
  name     = "invoke-pinned-watchdog"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.workspace_guard[each.key].qualified_arn },
    { Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.workspace_guard_failures[each.key].arn },
    { Effect = "Deny", NotAction = ["lambda:InvokeFunction", "sqs:SendMessage"], Resource = "*" }
  ] })
  lifecycle { prevent_destroy = true }
}

resource "aws_scheduler_schedule" "workspace_guard" {
  for_each                     = local.workspace_guards
  name                         = "${local.guard_name}-sweep"
  group_name                   = "default"
  schedule_expression_timezone = "UTC"
  action_after_completion      = "NONE"
  schedule_expression          = "rate(1 minute)"
  state                        = "ENABLED"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.workspace_guard[each.key].qualified_arn
    role_arn = aws_iam_role.workspace_guard_invoker[each.key].arn
    input    = jsonencode({ kind = "sweep", guard_id = local.guard_id })
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 3
    }
    dead_letter_config { arn = aws_sqs_queue.workspace_guard_failures[each.key].arn }
  }
  depends_on = [aws_iam_role_policy.workspace_guard_invoker, aws_lambda_function_event_invoke_config.workspace_guard]
  lifecycle { prevent_destroy = true }
}

resource "aws_cloudwatch_log_metric_filter" "workspace_guard_heartbeat" {
  for_each       = local.workspace_guards
  name           = "${local.guard_name}-heartbeat"
  log_group_name = aws_cloudwatch_log_group.workspace_guard[each.key].name
  pattern        = "{ $.kind = \"heartbeat\" }"
  metric_transformation {
    name      = "CompletedSweep"
    namespace = "WorkspaceGuard/${local.guard_id}"
    value     = "1"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_cloudwatch_metric_alarm" "workspace_guard_heartbeat" {
  for_each            = local.workspace_guards
  alarm_name          = "${local.guard_name}-missing-heartbeat"
  namespace           = "WorkspaceGuard/${local.guard_id}"
  metric_name         = "CompletedSweep"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  actions_enabled     = true
  alarm_actions       = [each.value.alarm_topic_arn]
  lifecycle { prevent_destroy = true }
}

resource "aws_cloudwatch_metric_alarm" "workspace_guard_errors" {
  for_each            = local.workspace_guards
  alarm_name          = "${local.guard_name}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.guard_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = [each.value.alarm_topic_arn]
  lifecycle { prevent_destroy = true }
}

output "workspace_guard" {
  value = var.workspace_guard == null ? null : {
    guard_id                = local.guard_id, function_arn = aws_lambda_function.workspace_guard["active"].qualified_arn,
    code_sha256             = var.workspace_guard.zip_sha256,
    invoker_role_arn        = aws_iam_role.workspace_guard_invoker["active"].arn,
    recurring_schedule_name = aws_scheduler_schedule.workspace_guard["active"].name,
    log_group               = aws_cloudwatch_log_group.workspace_guard["active"].name,
    failure_queue_arn       = aws_sqs_queue.workspace_guard_failures["active"].arn,
    alarm_names             = concat([aws_cloudwatch_metric_alarm.workspace_guard_heartbeat["active"].alarm_name, aws_cloudwatch_metric_alarm.workspace_guard_errors["active"].alarm_name], [for alarm in aws_cloudwatch_metric_alarm.workspace_guard_delivery : alarm.alarm_name])
  }
}

resource "aws_cloudwatch_metric_alarm" "workspace_guard_delivery" {
  for_each = var.workspace_guard == null ? {} : {
    throttles = { namespace = "AWS/Lambda", metric = "Throttles", dimensions = { FunctionName = local.guard_name } }
    failures  = { namespace = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", dimensions = { QueueName = aws_sqs_queue.workspace_guard_failures["active"].name } }
  }
  alarm_name          = "${local.guard_name}-${each.key}"
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dimensions
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = [var.workspace_guard.alarm_topic_arn]
  lifecycle { prevent_destroy = true }
}

# A static ceiling; the disposable inline policy further binds exact lease times,
# tags, image, network and state key. The workload never assumes this role.
resource "aws_iam_policy" "workspace_launch_boundary" {
  for_each = local.workspace_guards
  name     = "${var.resource_prefix}-workspace-launch-boundary"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ec2:Describe*", "iam:Get*", "iam:List*", "scheduler:GetSchedule", "ssm:GetDocument", "ssm:DescribeDocument", "s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "iam:PassRole", "ec2:RunInstances", "ec2:CreateTags"], Resource = "*" },
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", Condition = { StringNotEquals = { "ec2:InstanceType" = "r8i.2xlarge" } } },
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", Condition = { StringNotEquals = { "ec2:MetadataHttpTokens" = "required" } } },
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", Condition = { NumericGreaterThan = { "ec2:MetadataHttpPutResponseHopLimit" = "1" } } },
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:volume/*", Condition = { Bool = { "ec2:Encrypted" = "false" } } },
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", Condition = { StringNotEquals = { "aws:RequestTag/GuardId" = local.guard_id } } },
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", Condition = { StringNotEquals = { "aws:RequestTag/Project" = var.project_name } } },
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", Condition = { StringNotEquals = { "aws:RequestTag/Root" = "runner" } } },
    { Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*", Condition = { StringNotEquals = { "aws:RequestTag/ManagedBy" = "opentofu" } } }
  ] })
  lifecycle { prevent_destroy = true }
}
