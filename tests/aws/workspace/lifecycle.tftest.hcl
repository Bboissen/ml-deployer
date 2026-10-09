mock_provider "aws" {
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"}}]}" }
  }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000000:role/offline-role" } }
}

run "preparation_arms_deadline_without_compute" {
  command = plan
  assert {
    condition     = length(aws_instance.workspace) == 0 && aws_scheduler_schedule.workspace_deadline.state == "ENABLED" && aws_scheduler_schedule.workspace_deadline.flexible_time_window[0].mode == "OFF"
    error_message = "Preparation must arm a fixed deadline before any compute."
  }
  assert {
    condition     = jsondecode(aws_scheduler_schedule.workspace_deadline.target[0].input).lease_id == var.lease.id && aws_scheduler_schedule.workspace_deadline.target[0].arn == var.guard.function_arn && jsondecode(aws_ssm_document.terminal.content).inputs.runAsDefaultUser == "workspace"
    error_message = "Deadline must target the pinned guard and terminal must use non-root workspace."
  }
}

run "git_runtime_reads_only_workspace_secret" {
  command = plan
  variables {
    workspace_git_credential = {
      secret_arn             = "arn:aws:secretsmanager:us-east-1:000000000000:secret:fraud-detection/workspaces/fraud-detection-dev-01/git/aws-workspace-e2e-ABCdef"
      version_id             = "00000000-0000-0000-0000-000000000000"
      public_key_fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    }
  }
  assert {
    condition = length(aws_instance.workspace) == 0 && length([
      for statement in jsondecode(aws_iam_role_policy.workspace_storage["fraud-detection-dev-01"].policy).Statement : statement
      if statement.Sid == "ReadReviewedGitCredentials" || statement.Sid == "DenyOtherGitCredentials"
      ]) == 2 && alltrue([
      for statement in jsondecode(aws_iam_role_policy.workspace_storage["fraud-detection-dev-01"].policy).Statement :
      statement.Sid == "ReadReviewedGitCredentials" ? statement.Resource == [var.workspace_git_credential.secret_arn] :
      statement.Sid == "DenyOtherGitCredentials" ? statement.NotResource == [var.workspace_git_credential.secret_arn] : true
    ])
    error_message = "Non-compute preparation must allow only its exact runtime Git secret."
  }
}

run "guarded_launch_is_encrypted_disposable_and_tagged" {
  command = plan
  variables { phase = "launch" }
  assert {
    condition     = aws_instance.workspace[0].instance_type == "r8i.2xlarge" && aws_instance.workspace[0].root_block_device[0].encrypted && aws_instance.workspace[0].root_block_device[0].delete_on_termination && aws_instance.workspace[0].metadata_options[0].http_tokens == "required" && aws_instance.workspace[0].metadata_options[0].http_put_response_hop_limit == 1 && !aws_instance.workspace[0].disable_api_termination
    error_message = "Compute must retain exact capacity, encrypted disposable volume and IMDSv2."
  }
  assert {
    condition     = aws_instance.workspace[0].tags.LeaseId == var.lease.id && aws_instance.workspace[0].volume_tags == aws_instance.workspace[0].tags && !strcontains(aws_instance.workspace[0].user_data_base64, "secret")
    error_message = "Ownership/deadline must be atomic on instance and root volume."
  }
}

run "absent_guard_closes_launch" {
  command = plan
  variables {
    phase             = "launch"
    guard_observation = null
  }
  expect_failures = [aws_instance.workspace]
}

run "mismatched_guard_closes_launch" {
  command = plan
  variables {
    phase = "launch"
    guard_observation = {
      observed_at      = "2000-01-01T00:00:00Z", heartbeat_at = "2000-01-01T00:00:00Z",
      guard_id         = "wrong", code_sha256 = "wrong", recurrence_enabled = false,
      deadline_enabled = false, iam_verified = false, alarms_ok = false
    }
  }
  expect_failures = [aws_instance.workspace]
}

run "excessive_capacity_is_rejected" {
  command = plan
  variables { workspace_identity = merge(jsondecode(file("../../../../tests/aws/fixtures/workspace-identity.json")), { request = merge(jsondecode(file("../../../../tests/aws/fixtures/workspace-identity.json")).request, { resources = { cpus = 9, memory_mb = 60000, disk_gb = 25 }, operators = ["arn:aws:iam::000000000000:user/sposhfi-admin"] }) }) }
  expect_failures = [terraform_data.lease]
}

run "unreviewed_sku_is_rejected" {
  command = plan
  variables { instance_type = "m7i.large" }
  expect_failures = [var.instance_type]
}

run "retirement_revokes_launch_and_retains_deadline_until_compute_is_gone" {
  command = plan
  variables { phase = "retire" }
  assert {
    condition     = length(aws_instance.workspace) == 0 && aws_scheduler_schedule.workspace_deadline.state == "ENABLED" && jsondecode(aws_iam_role_policy.launch.policy).Statement[0].Effect == "Deny"
    error_message = "Retire must revoke launch while leaving deadline/profile protected during termination."
  }
}

run "stale_native_observation_fails_even_with_all_flags_true" {
  command = apply
  variables {
    phase = "launch"
    guard_observation = {
      observed_at        = "2000-01-01T00:00:00Z", heartbeat_at = "2000-01-01T00:00:00Z",
      guard_id           = substr(sha256("000000000000/us-east-1/ml-infra/workspace-v1"), 0, 32), code_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      recurrence_enabled = true, deadline_enabled = true, iam_verified = true, alarms_ok = true
    }
  }
  expect_failures = [aws_instance.workspace]
}
