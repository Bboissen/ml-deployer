mock_provider "aws" {
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_iam_policy_document" { defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } }
}
variables {
  aws_account_id    = "000000000000"
  aws_region        = "us-east-1"
  project_name      = "ml-infra"
  state_bucket_name = "ml-infra-tofu-state-000000000000-us-east-1-ws-v1"
}
run "protected_new_backend" {
  command = plan
  assert {
    condition     = !aws_s3_bucket.state.force_destroy && aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled" && aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "Fresh state storage must be persistent, versioned and private."
  }
  assert {
    condition     = aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced" && one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "Fresh backend retains encryption and owner enforcement."
  }
}
