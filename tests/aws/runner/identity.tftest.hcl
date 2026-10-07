mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::000000000000:role/offline-mocked-role" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
}

variables {
  workspace_identity = jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json"))
}

run "scoped_identity_and_native_temporary_profile" {
  command = plan
  assert {
    condition     = aws_iam_role.workspace["fraud-detection-dev-01"].permissions_boundary == jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).permissions_boundary_arn && aws_iam_role.workspace["fraud-detection-dev-01"].tags.workspace_id == "fraud-detection-dev-01" && length(aws_iam_role.workspace["fraud-detection-dev-01"].name) <= 64
    error_message = "Workspace role must use its project boundary, exact workspace tag and bounded stable name."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.workspace_ssm["fraud-detection-dev-01"].policy_arn == jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).session_policy_arn && aws_iam_role_policy_attachment.ssm.policy_arn == jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).session_policy_arn
    error_message = "Both workspace and retained batch roles must replace broad managed SSM permissions."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.workspace_storage["fraud-detection-dev-01"].policy).Statement[1].Resource == ["arn:aws:s3:::offline-project-example/projects/fraud-detection/workspaces/fraud-detection-dev-01/output/*"]
    error_message = "Effective write/multipart policy must bind exactly one workspace output prefix."
  }
  assert {
    condition     = aws_instance.runner.iam_instance_profile == aws_iam_instance_profile.runtime.name && output.workspace_identity_preparation["fraud-detection-dev-01"].compute_enabled == false
    error_message = "Milestone B must not connect prepared workspace identity to unaccepted historical compute."
  }
}

run "legacy_boundary_cannot_be_used_for_workspace" {
  command = plan
  variables {
    workspace_identity = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")), { permissions_boundary_arn = "arn:aws:iam::000000000000:policy/ml-infra-runtime-boundary" })
  }
  expect_failures = [var.workspace_identity]
}

run "cross_workspace_output_cannot_be_requested" {
  command = plan
  variables {
    workspace_identity = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")), {
      request = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).request, {
        storage = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).request.storage, { output_uri = "s3://offline-project-example/projects/fraud-detection/workspaces/fraud-detection-dev-02/output/" })
      })
    })
  }
  expect_failures = [var.workspace_identity]
}

run "unknown_request_fields_are_rejected" {
  command = plan
  variables { workspace_identity = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")), { request = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).request, { input_object_version = "historical-extra-field" }) }) }
  expect_failures = [var.workspace_identity]
}

run "overlapping_prefixes_are_rejected" {
  command = plan
  variables {
    workspace_identity = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")), {
      request = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).request, {
        storage = merge(jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).request.storage, { data_uri = jsondecode(file("../../../tests/aws/fixtures/workspace-identity.json")).request.storage.output_uri })
      })
    })
  }
  expect_failures = [var.workspace_identity]
}
