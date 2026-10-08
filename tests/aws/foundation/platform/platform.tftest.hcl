mock_provider "aws" {
  mock_resource "aws_sqs_queue" { defaults = { arn = "arn:aws:sqs:us-east-1:000000000000:offline-failures" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:000000000000:log-group:/aws/lambda/ml-infra-workspace-watchdog" } }
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
  state_bucket_arn        = "arn:aws:s3:::ml-infra-tofu-state-000000000000-us-east-1-ws-v1"
  deployer_principal_arns = ["arn:aws:iam::000000000000:user/sposhfi-admin"]
  ml_projects            = { demo = { ml_project_name = "demo", storage_mode = "auto" } }
}
run "independent_workspace_platform" {
  command = plan
  assert {
    condition     = aws_iam_role.deployer.name == "ml-infra-workspace-deployer" && length([for s in data.aws_iam_policy_document.deployer.statement : s if s.sid == "DenyDirectComputeLaunch" && s.effect == "Deny" && contains(s.actions, "ec2:RunInstances")]) == 1
    error_message = "Fresh routine identity must be distinct and cannot launch EC2 directly."
  }
  assert {
    condition     = length([for s in data.aws_iam_policy_document.deployer.statement : s if s.sid == "AssumeReceiptPublisherForControlPublication" || s.sid == "UseReviewedRunnerLaunchDependencies"]) == 0 && alltrue([for s in data.aws_iam_policy_document.deployer.statement : alltrue([for a in s.actions : a != "ec2:StartInstances" || s.effect == "Deny"])])
    error_message = "Fresh deployer must omit historical launch and receipt interfaces."
  }
  assert {
    condition     = length(aws_s3_bucket.project) == 1 && !aws_s3_bucket.project["demo"].force_destroy && length(aws_security_group.runner.ingress) == 0 && aws_scheduler_schedule.workspace_guard["active"].state == "ENABLED" && aws_lambda_function.workspace_guard["active"].reserved_concurrent_executions == -1
    error_message = "Independent platform needs persistent project storage, no ingress and the accepted watchdog."
  }
}
