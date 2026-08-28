#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'test-aws-platform-plan: %s\n' "$1" >&2
  exit 1
}

if (($# != 2)); then
  printf 'usage: %s PLATFORM_PLAN_JSON TASK_B_PLAN_REVIEW_RECEIPT_JSON\n' "$0" >&2
  exit 2
fi

readonly PLAN_JSON="$1"
readonly REVIEW_RECEIPT="$2"

for command_name in jq sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: ${command_name}"
done

[[ -f "$PLAN_JSON" ]] || fail "plan JSON does not exist: ${PLAN_JSON}"
[[ -f "$REVIEW_RECEIPT" ]] || fail "review receipt does not exist: ${REVIEW_RECEIPT}"
jq -e . "$PLAN_JSON" >/dev/null || fail 'plan JSON is invalid'
jq -e . "$REVIEW_RECEIPT" >/dev/null || fail 'review receipt JSON is invalid'

readonly EXPECTED_PLAN_JSON_SHA256="$(jq -er '.saved_plan.json_sha256' "$REVIEW_RECEIPT")"
readonly ACTUAL_PLAN_JSON_SHA256="$(sha256sum "$PLAN_JSON" | awk '{print $1}')"
[[ "$ACTUAL_PLAN_JSON_SHA256" == "$EXPECTED_PLAN_JSON_SHA256" ]] ||
  fail 'plan JSON checksum does not match the reviewed receipt'

readonly EXPECTED_CREATE_ADDRESSES="$({
  jq -cn '[
    "aws_ecr_repository.runner",
    "aws_iam_policy.runtime_boundary",
    "aws_iam_policy.scheduler_boundary",
    "aws_iam_role.deployer",
    "aws_iam_role.receipt_publisher",
    "aws_iam_role_policy.deployer",
    "aws_iam_role_policy.receipt_publisher",
    "aws_internet_gateway.runner",
    "aws_route_table.runner",
    "aws_route_table_association.runner",
    "aws_s3_bucket.workload[\"data\"]",
    "aws_s3_bucket.workload[\"results\"]",
    "aws_s3_bucket_lifecycle_configuration.workload[\"data\"]",
    "aws_s3_bucket_lifecycle_configuration.workload[\"results\"]",
    "aws_s3_bucket_ownership_controls.workload[\"data\"]",
    "aws_s3_bucket_ownership_controls.workload[\"results\"]",
    "aws_s3_bucket_policy.data",
    "aws_s3_bucket_policy.results",
    "aws_s3_bucket_public_access_block.workload[\"data\"]",
    "aws_s3_bucket_public_access_block.workload[\"results\"]",
    "aws_s3_bucket_server_side_encryption_configuration.workload[\"data\"]",
    "aws_s3_bucket_server_side_encryption_configuration.workload[\"results\"]",
    "aws_s3_bucket_versioning.workload[\"data\"]",
    "aws_s3_bucket_versioning.workload[\"results\"]",
    "aws_security_group.runner",
    "aws_subnet.runner",
    "aws_vpc.runner"
  ] | sort'
})"

readonly ACTUAL_CREATE_ADDRESSES="$({
  jq -c '[.resource_changes[] | select(.change.actions == ["create"]) | .address] | sort' "$PLAN_JSON"
})"
[[ "$ACTUAL_CREATE_ADDRESSES" == "$EXPECTED_CREATE_ADDRESSES" ]] ||
  fail 'create addresses do not match the closed Task B allowlist'

readonly EXPECTED_DATA_READ_ADDRESSES="$({
  jq -cn '[
    "data.aws_iam_policy_document.data_bucket",
    "data.aws_iam_policy_document.deployer",
    "data.aws_iam_policy_document.receipt_publisher",
    "data.aws_iam_policy_document.receipt_publisher_assume",
    "data.aws_iam_policy_document.results_bucket",
    "data.aws_iam_policy_document.runtime_boundary"
  ] | sort'
})"

readonly ACTUAL_DATA_READ_ADDRESSES="$({
  jq -c '[.resource_changes[] | select(.change.actions == ["read"]) | .address] | sort' "$PLAN_JSON"
})"
[[ "$ACTUAL_DATA_READ_ADDRESSES" == "$EXPECTED_DATA_READ_ADDRESSES" ]] ||
  fail 'data reads do not match the closed Task B allowlist'

jq -e --slurpfile receipt "$REVIEW_RECEIPT" '
  . as $plan |
  def binding: $receipt[0].binding;
  def change($address): first($plan.resource_changes[] | select(.address == $address) | .change);
  def after($address): change($address).after;
  def unknown($address): change($address).after_unknown;
  def config($address): first($plan.configuration.root_module.resources[] | select(.address == $address));
  def sorted: sort;

  .format_version == "1.2" and
  .terraform_version == "1.12.3" and
  .configuration.provider_config.aws.full_name == "registry.opentofu.org/hashicorp/aws" and
  .configuration.provider_config.aws.version_constraint == "6.61.0" and
  all(.resource_changes[]; .change.actions == ["create"] or .change.actions == ["read"]) and
  ([.resource_changes[] | select(.change.actions == ["create"])] | length) == 27 and
  ([.resource_changes[] | select(.change.actions == ["read"])] | length) == 6 and

  .variables.aws_account_id.value == binding.aws_account_id and
  .variables.aws_region.value == binding.aws_region and
  .variables.availability_zone.value == binding.availability_zone and
  .variables.project_name.value == binding.project_name and
  .variables.resource_prefix.value == binding.resource_prefix and
  .variables.state_bucket_arn.value == ("arn:aws:s3:::" + binding.state_bucket) and
  .variables.data_bucket_name.value == binding.data_bucket and
  .variables.results_bucket_name.value == binding.results_bucket and
  .variables.ecr_repository_name.value == binding.ecr_repository and
  .variables.vpc_cidr.value == binding.vpc_cidr and
  .variables.runner_subnet_cidr.value == binding.runner_subnet_cidr and
  .variables.deployer_principal_arns.value == [binding.deployer_principal] and
  .variables.tags.value == binding.tags and

  after("aws_s3_bucket.workload[\"data\"]").bucket == binding.data_bucket and
  after("aws_s3_bucket.workload[\"results\"]").bucket == binding.results_bucket and
  after("aws_s3_bucket.workload[\"data\"]").force_destroy == false and
  after("aws_s3_bucket.workload[\"results\"]").force_destroy == false and
  all(["data", "results"][];
    . as $name |
    after("aws_s3_bucket_public_access_block.workload[\"" + $name + "\"]") as $block |
    $block.block_public_acls == true and
    $block.block_public_policy == true and
    $block.ignore_public_acls == true and
    $block.restrict_public_buckets == true and
    after("aws_s3_bucket_ownership_controls.workload[\"" + $name + "\"]").rule[0].object_ownership == "BucketOwnerEnforced" and
    after("aws_s3_bucket_versioning.workload[\"" + $name + "\"]").versioning_configuration[0].status == "Enabled" and
    after("aws_s3_bucket_server_side_encryption_configuration.workload[\"" + $name + "\"]").rule[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256" and
    after("aws_s3_bucket_lifecycle_configuration.workload[\"" + $name + "\"]").rule[0].abort_incomplete_multipart_upload[0].days_after_initiation == 7
  ) and

  after("aws_ecr_repository.runner").name == binding.ecr_repository and
  after("aws_ecr_repository.runner").image_tag_mutability == "IMMUTABLE" and
  after("aws_ecr_repository.runner").force_delete == false and
  after("aws_ecr_repository.runner").image_scanning_configuration[0].scan_on_push == true and
  after("aws_ecr_repository.runner").encryption_configuration[0].encryption_type == "AES256" and

  after("aws_vpc.runner").cidr_block == binding.vpc_cidr and
  after("aws_vpc.runner").enable_dns_support == true and
  after("aws_vpc.runner").enable_dns_hostnames == true and
  after("aws_subnet.runner").cidr_block == binding.runner_subnet_cidr and
  after("aws_subnet.runner").availability_zone == binding.availability_zone and
  after("aws_subnet.runner").map_public_ip_on_launch == false and
  ((after("aws_security_group.runner").ingress // []) | length) == 0 and
  after("aws_security_group.runner").egress[0].protocol == "-1" and
  after("aws_security_group.runner").egress[0].cidr_blocks == ["0.0.0.0/0"] and
  after("aws_route_table.runner").route[0].cidr_block == "0.0.0.0/0" and
  (config("aws_route_table.runner").expressions.route.references | index("aws_internet_gateway.runner.id")) != null and

  after("aws_iam_role.deployer").name == (binding.resource_prefix + "-tofu-deployer") and
  (after("aws_iam_role.deployer").assume_role_policy | fromjson).Statement[0].Principal.AWS == binding.deployer_principal and
  after("aws_iam_role.receipt_publisher").name == (binding.resource_prefix + "-receipt-publisher") and
  after("aws_iam_policy.runtime_boundary").name == (binding.resource_prefix + "-runtime-boundary") and
  after("aws_iam_policy.scheduler_boundary").name == (binding.resource_prefix + "-scheduler-boundary") and
  (after("aws_iam_policy.scheduler_boundary").policy | fromjson).Statement == [{
    Action: "ec2:TerminateInstances",
    Condition: {StringEquals: {"ec2:ResourceTag/Project": binding.project_name}},
    Effect: "Allow",
    Resource: "*",
    Sid: "TerminateTaggedDemoRunner"
  }] and

  unknown("aws_iam_policy.runtime_boundary").policy == true and
  unknown("aws_iam_role.receipt_publisher").assume_role_policy == true and
  unknown("aws_iam_role_policy.deployer").policy == true and
  unknown("aws_iam_role_policy.receipt_publisher").policy == true and
  unknown("aws_s3_bucket_policy.data").policy == true and
  unknown("aws_s3_bucket_policy.results").policy == true and

  all([
    "aws_ecr_repository.runner",
    "aws_iam_policy.runtime_boundary",
    "aws_iam_policy.scheduler_boundary",
    "aws_iam_role.deployer",
    "aws_iam_role.receipt_publisher",
    "aws_internet_gateway.runner",
    "aws_route_table.runner",
    "aws_s3_bucket.workload[\"data\"]",
    "aws_s3_bucket.workload[\"results\"]",
    "aws_security_group.runner",
    "aws_subnet.runner",
    "aws_vpc.runner"
  ][];
    . as $address |
    after($address).tags_all.Project == binding.project_name and
    after($address).tags_all.Root == "platform" and
    after($address).tags_all.ManagedBy == "opentofu" and
    after($address).tags_all.Environment == binding.tags.Environment and
    after($address).tags_all.Owner == binding.tags.Owner
  )
' "$PLAN_JSON" >/dev/null || fail 'saved plan violates the Task B binding or resource policy'

if rg -n --ignore-case 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|aws_secret_access_key' "$PLAN_JSON" >/dev/null; then
  fail 'secret-shaped material exists in the saved plan JSON'
fi

if [[ "${AWS_PLATFORM_PLAN_VALIDATION_ONLY:-0}" != "1" ]]; then
  temporary_directory="$(mktemp -d)"
  trap 'rm -rf -- "$temporary_directory"' EXIT

  verify_rejected_mutation() {
    local case_name="$1"
    local jq_filter="$2"
    local mutated_plan="${temporary_directory}/${case_name}.plan.json"
    local mutated_receipt="${temporary_directory}/${case_name}.receipt.json"
    local mutated_sha256

    jq "$jq_filter" "$PLAN_JSON" >"$mutated_plan"
    mutated_sha256="$(sha256sum "$mutated_plan" | awk '{print $1}')"
    jq --arg sha256 "$mutated_sha256" '.saved_plan.json_sha256 = $sha256' \
      "$REVIEW_RECEIPT" >"$mutated_receipt"

    if AWS_PLATFORM_PLAN_VALIDATION_ONLY=1 "$0" "$mutated_plan" "$mutated_receipt" >/dev/null 2>&1; then
      fail "validator accepted negative mutation: ${case_name}"
    fi
  }

  verify_rejected_mutation delete-action \
    '(.resource_changes[] | select(.address == "aws_vpc.runner") | .change.actions) = ["delete"]'
  verify_rejected_mutation wrong-region '.variables.aws_region.value = "us-west-2"'
  verify_rejected_mutation ingress-rule \
    '(.resource_changes[] | select(.address == "aws_security_group.runner") | .change.after.ingress) = [{protocol:"tcp",from_port:22,to_port:22,cidr_blocks:["0.0.0.0/0"]}]'
fi

printf 'test-aws-platform-plan: PASS\n'
