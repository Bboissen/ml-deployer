mock_provider "aws" {
  mock_data "aws_s3_bucket" {
    defaults = { bucket_region = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
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

run "no_projects_preserves_historical_ownership" {
  command = plan
  assert {
    condition     = length(aws_s3_bucket.project) == 0 && toset(keys(aws_s3_bucket.workload)) == toset(["data", "results"])
    error_message = "Default configuration must preserve historical storage without creating project storage."
  }
  assert {
    condition     = alltrue([for b in aws_s3_bucket.workload : b.force_destroy == false])
    error_message = "Historical storage must retain content."
  }
}

run "unassigned_auto_creates_one_versioned_private_project_bucket" {
  command = plan
  variables {
    ml_projects = { fraud-detection = { ml_project_name = "fraud-detection" } }
  }
  assert {
    condition     = length(aws_s3_bucket.project) == 1 && aws_s3_bucket.project["fraud-detection"].bucket == "ml-fraud-detection-${substr(sha256("000000000000/us-east-1/fraud-detection"), 0, 16)}" && !aws_s3_bucket.project["fraud-detection"].force_destroy
    error_message = "Auto must create one stable bucket per project, with retained contents."
  }
  assert {
    condition     = aws_s3_bucket_versioning.project["fraud-detection"].versioning_configuration[0].status == "Enabled" && aws_s3_bucket_public_access_block.project["fraud-detection"].block_public_acls && aws_s3_bucket_public_access_block.project["fraud-detection"].block_public_policy && aws_s3_bucket_public_access_block.project["fraud-detection"].ignore_public_acls && aws_s3_bucket_public_access_block.project["fraud-detection"].restrict_public_buckets
    error_message = "New project storage must be private and recoverable."
  }
  assert {
    condition     = jsondecode(aws_iam_policy.session_manager.policy).Statement[0].Action == local.session_manager_actions && length(local.session_manager_actions) == 5
    error_message = "Management must use the five minimal agent actions."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_policy.project_workspace_boundary["fraud-detection"].policy).Statement[1].Resource, "arn:aws:s3:::${local.project_bucket_names["fraud-detection"]}/projects/fraud-detection/workspaces/$${aws:PrincipalTag/workspace_id}/output/*")
    error_message = "Boundary must isolate outputs by immutable workload principal tag."
  }
  assert {
    condition     = length([for s in data.aws_iam_policy_document.runtime_boundary.statement : s if s.sid == "DenyParameterStoreReads" && s.effect == "Deny" && contains(s.actions, "ssm:GetParameter*")]) == 1 && length([for s in data.aws_iam_policy_document.runtime_boundary.statement : s if s.sid == "UseSystemsManagerControlChannels" && toset(s.actions) == toset(local.session_manager_actions)]) == 1
    error_message = "Historical boundary must also narrow and explicitly deny parameter reads."
  }
}

run "existing_external_is_referenced_without_resources_or_policy_replacement" {
  command = plan
  variables {
    ml_projects = {
      fraud-detection = {
        ml_project_name = "fraud-detection"
        storage_mode    = "existing"
        assignment = {
          bucket_name    = "offline-external-example", ownership = "external", resource_address = "", state_key = "",
          aws_account_id = "000000000000", aws_region = "us-east-1", review_sha256 = sha256("offline-review"),
          protections    = { versioning_enabled = true, public_access_blocked = true, owner_enforced = true, aes256_encryption = true }
        }
      }
    }
  }
  assert {
    condition     = length(aws_s3_bucket.project) == 0 && length(aws_s3_bucket_policy.project) == 0 && length(data.aws_s3_bucket.assigned_project) == 1 && local.project_storage["fraud-detection"].data_uri == "s3://offline-external-example/projects/fraud-detection/data/"
    error_message = "An external assignment must not be imported, renamed or mutated."
  }
}

run "wrong_observed_bucket_region_is_rejected" {
  command = plan
  variables {
    ml_projects = { fraud-detection = {
      ml_project_name = "fraud-detection"
      assignment = {
        bucket_name    = "offline-external-example", ownership = "external", resource_address = "", state_key = "",
        aws_account_id = "000000000000", aws_region = "us-east-1", review_sha256 = sha256("offline-review"),
        protections    = { versioning_enabled = true, public_access_blocked = true, owner_enforced = true, aes256_encryption = true }
      }
    } }
  }
  override_data {
    target = data.aws_s3_bucket.assigned_project
    values = { bucket_region = "us-west-2" }
  }
  expect_failures = [terraform_data.project_storage_checks]
}

run "retained_platform_bucket_keeps_its_original_address" {
  command = plan
  variables {
    ml_projects = {
      fraud-detection = {
        ml_project_name = "fraud-detection"
        assignment = {
          bucket_name = "replace-ml-infra-aws-data-unique", ownership = "platform-managed", resource_address = "aws_s3_bucket.workload[\"data\"]",
          state_key   = "aws/000000000000/us-east-1/platform/platform.tfstate", aws_account_id = "000000000000", aws_region = "us-east-1", review_sha256 = sha256("offline-review"),
          protections = { versioning_enabled = true, public_access_blocked = true, owner_enforced = true, aes256_encryption = true }
        }
      }
    }
  }
  assert {
    condition     = length(aws_s3_bucket.project) == 0 && local.project_storage["fraud-detection"].resource_address == "aws_s3_bucket.workload[\"data\"]"
    error_message = "Retained storage must stay at its old address and keep its content."
  }
}

run "existing_without_assignment_is_rejected" {
  command = plan
  variables { ml_projects = { fraud-detection = { ml_project_name = "fraud-detection", storage_mode = "existing" } } }
  expect_failures = [var.ml_projects]
}

run "incorrect_region_is_rejected" {
  command = plan
  variables {
    ml_projects = { fraud-detection = {
      ml_project_name = "fraud-detection"
      assignment = {
        bucket_name    = "offline-external-example", ownership = "external", resource_address = "", state_key = "",
        aws_account_id = "000000000000", aws_region = "us-west-2", review_sha256 = sha256("offline-review"),
        protections    = { versioning_enabled = true, public_access_blocked = true, owner_enforced = true, aes256_encryption = true }
      }
    } }
  }
  expect_failures = [var.ml_projects]
}

run "unprotected_external_storage_is_rejected" {
  command = plan
  variables {
    ml_projects = { fraud-detection = {
      ml_project_name = "fraud-detection"
      assignment = {
        bucket_name    = "offline-external-example", ownership = "external", resource_address = "", state_key = "",
        aws_account_id = "000000000000", aws_region = "us-east-1", review_sha256 = sha256("offline-review"),
        protections    = { versioning_enabled = false, public_access_blocked = true, owner_enforced = true, aes256_encryption = true }
      }
    } }
  }
  expect_failures = [terraform_data.project_storage_checks]
}

run "state_reuse_is_rejected" {
  command = plan
  variables {
    ml_projects = { fraud-detection = {
      ml_project_name = "fraud-detection"
      assignment = {
        bucket_name    = "replace-ml-infra-aws-state-unique", ownership = "external", resource_address = "", state_key = "",
        aws_account_id = "000000000000", aws_region = "us-east-1", review_sha256 = sha256("offline-review"),
        protections    = { versioning_enabled = true, public_access_blocked = true, owner_enforced = true, aes256_encryption = true }
      }
    } }
  }
  expect_failures = [terraform_data.project_storage_checks]
}
