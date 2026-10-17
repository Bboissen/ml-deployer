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
  ml_projects             = { demo = { ml_project_name = "demo", storage_mode = "auto" } }
}
run "independent_workspace_platform" {
  command = plan
  assert {
    condition     = aws_iam_role.deployer.name == "ml-infra-workspace-deployer" && length([for s in data.aws_iam_policy_document.deployer.statement : s if s.sid == "DenyDirectComputeLaunch" && s.effect == "Deny" && contains(s.actions, "ec2:RunInstances")]) == 1
    error_message = "Fresh routine identity must be distinct and cannot launch EC2 directly."
  }
  assert {
    condition = length([
      for statement in data.aws_iam_policy_document.deployer.statement : statement
      if statement.sid == "DenyReviewedOperatorPolicyMutation" && statement.effect == "Deny" &&
      toset(statement.actions) == toset(["iam:*"]) &&
      toset(statement.resources) == toset(var.deployer_principal_arns)
    ]) == 1
    error_message = "The routine deployer must not grant itself broader permissions through its operator principal."
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

run "git_boundary_reads_only_reviewed_secret" {
  command = plan
  variables {
    workspace_git_secret_arns = {
      demo = ["arn:aws:secretsmanager:us-east-1:000000000000:secret:demo/workspaces/demo-dev-01/git/aws-workspace-e2e-ABCdef"]
    }
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_policy.project_workspace_boundary["demo"].policy).Statement :
      statement.Sid == "ReadReviewedGitCredentials" ? tolist(statement.Resource) == tolist(var.workspace_git_secret_arns.demo) :
      statement.Sid == "DenyOtherGitCredentials" ? tolist(statement.NotResource) == tolist(var.workspace_git_secret_arns.demo) :
      statement.Sid == "DenyOtherActionsIncludingDeletionAndAdministration" ? contains(statement.NotAction, "secretsmanager:GetSecretValue") : true
    ])
    error_message = "Git access must permit only the exact reviewed secret and exclude it from the closed deny list."
  }
  assert {
    condition     = length([for statement in jsondecode(aws_iam_policy.project_workspace_boundary["demo"].policy).Statement : statement if statement.Sid == "DenyStateStorage" || statement.Sid == "DenyWritesOutsideOwnOutput"]) == 2
    error_message = "Credential access must retain state and unrelated storage denial."
  }
}

run "readable_storage_names_and_permissions" {
  command = plan
  variables {
    storage_layout = "readable-v1"
  }
  assert {
    condition     = aws_s3_bucket.project["demo"].bucket == "demo-storage-000000000000-us-east-1" && local.project_storage["demo"].data_prefix == "datasets/" && local.project_storage["demo"].output_prefix_template == "results/<workspace_id>/"
    error_message = "Readable storage must expose datasets and results directly under an explicit project storage bucket."
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_policy.project_workspace_boundary["demo"].policy).Statement :
      statement.Sid == "ReadDatasetAndOwnOutputVersions" ? toset(statement.Resource) == toset(["arn:aws:s3:::demo-storage-000000000000-us-east-1/datasets/*", "arn:aws:s3:::demo-storage-000000000000-us-east-1/results/$${aws:PrincipalTag/workspace_id}/*"]) :
      statement.Sid == "WriteOwnOutputAndMultipart" ? toset(statement.Resource) == toset(["arn:aws:s3:::demo-storage-000000000000-us-east-1/results/$${aws:PrincipalTag/workspace_id}/*"]) :
      statement.Sid == "DenyStateStorage" ? contains(statement.Resource, var.state_bucket_arn) :
      statement.Sid == "DenyWritesOutsideOwnOutput" ? toset(statement.NotResource) == toset(["arn:aws:s3:::demo-storage-000000000000-us-east-1/results/$${aws:PrincipalTag/workspace_id}/*"]) : true
    ])
    error_message = "Readable namespaces must retain exact workspace output grants and deny dataset/state writes."
  }
}

run "git_boundary_rejects_another_account" {
  command = plan
  variables {
    workspace_git_secret_arns = {
      demo = ["arn:aws:secretsmanager:us-east-1:999999999999:secret:demo/workspaces/demo-dev-01/git/aws-workspace-e2e-ABCdef"]
    }
  }
  expect_failures = [var.workspace_git_secret_arns]
}
