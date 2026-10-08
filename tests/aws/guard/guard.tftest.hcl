mock_provider "aws" {
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:000000000000:offline-failures" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:000000000000:log-group:/aws/lambda/ml-infra-workspace-watchdog" }
  }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_iam_policy_document" { defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000000:role/offline-role" } }
  mock_resource "aws_lambda_function" { defaults = { version = "1", qualified_arn = "arn:aws:lambda:us-east-1:000000000000:function:ml-infra-workspace-watchdog:1" } }
}
variables {
  aws_account_id          = "000000000000"
  aws_region              = "us-east-1"
  availability_zone       = "us-east-1a"
  project_name            = "ml-infra"
  resource_prefix         = "ml-infra"
  state_bucket_arn        = "arn:aws:s3:::replace-ml-infra-aws-state-unique"
  data_bucket_name        = "replace-ml-infra-aws-data-unique"
  results_bucket_name     = "replace-ml-infra-aws-results-unique"
  ecr_repository_name     = "ml-infra/runner"
  deployer_principal_arns = ["arn:aws:iam::000000000000:user/offline-example"]
}
run "persistent_sweep_failure_path_and_runtime_ceiling" {
  command = plan
  assert {
    condition     = aws_scheduler_schedule.workspace_guard["active"].state == "ENABLED" && aws_scheduler_schedule.workspace_guard["active"].schedule_expression == "rate(1 minute)" && aws_lambda_function.workspace_guard["active"].timeout == 30 && aws_lambda_function.workspace_guard["active"].reserved_concurrent_executions == -1 && aws_lambda_function_event_invoke_config.workspace_guard["active"].maximum_event_age_in_seconds == 300 && aws_sqs_queue.workspace_guard_failures["active"].sqs_managed_sse_enabled
    error_message = "Persistent fallback must remain independent, bounded and observable."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.workspace_guard_delivery) == 2 && aws_cloudwatch_metric_alarm.workspace_guard_heartbeat["active"].treat_missing_data == "breaching" && alltrue([for b in aws_s3_bucket.workload : !b.force_destroy])
    error_message = "Missing heartbeat/failure alarms and retained historical storage are mandatory."
  }
  assert {
    condition     = length([for s in data.aws_iam_policy_document.deployer.statement : s if s.sid == "LaunchTaggedRunner" && s.effect == "Deny" && length(s.condition) == 0]) == 1
    error_message = "Normal deployer must lose its historical unguarded launch permission."
  }
}
