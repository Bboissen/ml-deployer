#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'test-aws-platform-iam-contract: %s\n' "$1" >&2
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

readonly EXPECTED_PLAN_JSON_SHA256="$(jq -er '.saved_plan.json_sha256' "$REVIEW_RECEIPT")"
readonly ACTUAL_PLAN_JSON_SHA256="$(sha256sum "$PLAN_JSON" | awk '{print $1}')"
[[ "$ACTUAL_PLAN_JSON_SHA256" == "$EXPECTED_PLAN_JSON_SHA256" ]] ||
  fail 'plan JSON checksum does not match the reviewed receipt'

jq -e --slurpfile receipt "$REVIEW_RECEIPT" '
  def binding: $receipt[0].binding;
  def planned($address): first(.resource_changes[] | select(.address == $address) | .change.after);
  def config($address): first(.configuration.root_module.resources[] | select(.address == $address));
  def statements($address): config($address).expressions.statement;
  def statement($address; $sid): first(statements($address)[] | select(.sid.constant_value == $sid));
  def planned_statement($address; $sid): first(planned($address).statement[] | select(.sid == $sid));
  def sids($address): [statements($address)[].sid.constant_value] | sort;
  def exact_actions($address; $sid; $actions): (statement($address; $sid).actions.constant_value | sort) == ($actions | sort);
  def exact_condition($address; $sid; $test; $variable; $values):
    statement($address; $sid).condition == [{
      test: {constant_value: $test},
      values: {constant_value: $values},
      variable: {constant_value: $variable}
    }];

  sids("data.aws_iam_policy_document.deployer") == ([
    "AssumeReceiptPublisherForControlPublication",
    "LaunchTaggedRunner",
    "ManageOnlyBoundedRunnerRoles",
    "ManageOnlyRunnerDeadlineSchedules",
    "ManageOnlyRunnerInstanceProfiles",
    "ManageTaggedRunnerLifecycle",
    "PassOnlyRunnerRolesToNativeServices",
    "ReadRunnerInfrastructure",
    "ReadWriteRunnerRemoteStateObjects",
    "RequireAcceptedRunnerBoundaries",
    "TagRunnerAtLaunch",
    "UseRunnerRemoteState"
  ] | sort) and
  all(statements("data.aws_iam_policy_document.deployer")[]; .effect.constant_value == "Allow") and
  exact_actions("data.aws_iam_policy_document.deployer"; "UseRunnerRemoteState"; ["s3:GetBucketLocation", "s3:ListBucket"]) and
  planned_statement("data.aws_iam_policy_document.deployer"; "UseRunnerRemoteState").resources == ["arn:aws:s3:::" + binding.state_bucket] and
  exact_actions("data.aws_iam_policy_document.deployer"; "ReadWriteRunnerRemoteStateObjects"; ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]) and
  planned_statement("data.aws_iam_policy_document.deployer"; "ReadWriteRunnerRemoteStateObjects").resources == [
    "arn:aws:s3:::" + binding.state_bucket + "/aws/" + binding.aws_account_id + "/" + binding.aws_region + "/runner/*"
  ] and
  exact_actions("data.aws_iam_policy_document.deployer"; "LaunchTaggedRunner"; ["ec2:RunInstances"]) and
  planned_statement("data.aws_iam_policy_document.deployer"; "LaunchTaggedRunner").condition == [{
    test: "StringEquals",
    values: [binding.project_name],
    variable: "aws:RequestTag/Project"
  }] and
  exact_actions("data.aws_iam_policy_document.deployer"; "ManageTaggedRunnerLifecycle"; [
    "ec2:ModifyInstanceAttribute", "ec2:StartInstances", "ec2:StopInstances", "ec2:TerminateInstances"
  ]) and
  planned_statement("data.aws_iam_policy_document.deployer"; "ManageTaggedRunnerLifecycle").condition == [{
    test: "StringEquals",
    values: [binding.project_name],
    variable: "ec2:ResourceTag/Project"
  }] and
  exact_actions("data.aws_iam_policy_document.deployer"; "TagRunnerAtLaunch"; ["ec2:CreateTags"]) and
  exact_condition("data.aws_iam_policy_document.deployer"; "TagRunnerAtLaunch"; "StringEquals"; "ec2:CreateAction"; ["RunInstances"]) and
  planned_statement("data.aws_iam_policy_document.deployer"; "ManageOnlyBoundedRunnerRoles").resources == [
    "arn:aws:iam::" + binding.aws_account_id + ":role/" + binding.resource_prefix + "-run-*"
  ] and
  exact_actions("data.aws_iam_policy_document.deployer"; "RequireAcceptedRunnerBoundaries"; ["iam:CreateRole"]) and
  planned_statement("data.aws_iam_policy_document.deployer"; "RequireAcceptedRunnerBoundaries").condition[0].variable == "iam:PermissionsBoundary" and
  (first(config("data.aws_iam_policy_document.deployer").expressions.statement[] |
    select(.sid.constant_value == "RequireAcceptedRunnerBoundaries")).condition[0].values.references) == [
      "aws_iam_policy.runtime_boundary.arn",
      "aws_iam_policy.runtime_boundary",
      "aws_iam_policy.scheduler_boundary.arn",
      "aws_iam_policy.scheduler_boundary"
  ] and
  planned_statement("data.aws_iam_policy_document.deployer"; "ManageOnlyRunnerInstanceProfiles").resources == [
    "arn:aws:iam::" + binding.aws_account_id + ":instance-profile/" + binding.resource_prefix + "-run-*"
  ] and
  planned_statement("data.aws_iam_policy_document.deployer"; "PassOnlyRunnerRolesToNativeServices").condition == [{
    test: "StringEquals",
    values: ["ec2.amazonaws.com", "scheduler.amazonaws.com"],
    variable: "iam:PassedToService"
  }] and
  planned_statement("data.aws_iam_policy_document.deployer"; "ManageOnlyRunnerDeadlineSchedules").resources == [
    "arn:aws:scheduler:" + binding.aws_region + ":" + binding.aws_account_id + ":schedule/default/" + binding.resource_prefix + "-run-*"
  ] and

  sids("data.aws_iam_policy_document.runtime_boundary") == ([
    "ConditionallyCreateOwnLocalReceiptHandoff",
    "DenyReceiptControlNamespace",
    "DenyReceiptPublisherAssumption",
    "DenyStateStorage",
    "GetECRAuthorizationToken",
    "ListGenericData",
    "PullCanonicalImageFromProviderLocalECR",
    "ReadGenericDataObjects",
    "ReadResultsBucketMetadata",
    "ReadRunSpecifications",
    "UseSystemsManagerControlChannels",
    "WriteOwnLogsAndResults"
  ] | sort) and
  planned_statement("data.aws_iam_policy_document.runtime_boundary"; "DenyStateStorage").effect == "Deny" and
  planned_statement("data.aws_iam_policy_document.runtime_boundary"; "DenyStateStorage").actions == ["s3:*"] and
  planned_statement("data.aws_iam_policy_document.runtime_boundary"; "DenyStateStorage").resources == [
    "arn:aws:s3:::" + binding.state_bucket,
    "arn:aws:s3:::" + binding.state_bucket + "/*"
  ] and
  statement("data.aws_iam_policy_document.runtime_boundary"; "DenyReceiptControlNamespace").effect.constant_value == "Deny" and
  statement("data.aws_iam_policy_document.runtime_boundary"; "DenyReceiptPublisherAssumption").effect.constant_value == "Deny" and
  exact_actions("data.aws_iam_policy_document.runtime_boundary"; "DenyReceiptPublisherAssumption"; ["sts:AssumeRole"]) and
  exact_condition("data.aws_iam_policy_document.runtime_boundary"; "ConditionallyCreateOwnLocalReceiptHandoff"; "StringEquals"; "s3:if-none-match"; ["*"]) and

  sids("data.aws_iam_policy_document.receipt_publisher") == ([
    "ConditionallyCreateControlEvidenceAndReceipts",
    "ReadBoundedRunnerEvidence",
    "ReadResultsBucketLocation",
    "ReadRunnerDeadlineSchedule",
    "ReadRunnerLifecycleFacts"
  ] | sort) and
  exact_actions("data.aws_iam_policy_document.receipt_publisher"; "ReadRunnerLifecycleFacts"; ["ec2:DescribeInstances"]) and
  exact_actions("data.aws_iam_policy_document.receipt_publisher"; "ReadRunnerDeadlineSchedule"; ["scheduler:GetSchedule"]) and
  planned_statement("data.aws_iam_policy_document.receipt_publisher"; "ReadRunnerDeadlineSchedule").resources == [
    "arn:aws:scheduler:" + binding.aws_region + ":" + binding.aws_account_id + ":schedule/default/" + binding.resource_prefix + "-run-*-stop"
  ] and
  exact_condition("data.aws_iam_policy_document.receipt_publisher"; "ConditionallyCreateControlEvidenceAndReceipts"; "StringEquals"; "s3:if-none-match"; ["*"]) and
  planned_statement("data.aws_iam_policy_document.receipt_publisher"; "ReadBoundedRunnerEvidence").resources == [
    "arn:aws:s3:::" + binding.results_bucket + "/runs/*/control-input/execution-receipt.local.json",
    "arn:aws:s3:::" + binding.results_bucket + "/runs/*/logs/bootstrap.log",
    "arn:aws:s3:::" + binding.results_bucket + "/runs/*/results/result-manifest.json"
  ] and

  sids("data.aws_iam_policy_document.results_bucket") == ([
    "DenyControlDeletion",
    "DenyControlOverwrite",
    "DenyControlWritesFromOtherPrincipals",
    "DenyControlWritesWithoutConditionalCreate",
    "DenyInsecureTransport",
    "DenyLocalReceiptHandoffOverwrite",
    "DenyLocalReceiptHandoffWithoutConditionalCreate"
  ] | sort) and
  all(statements("data.aws_iam_policy_document.results_bucket")[]; .effect.constant_value == "Deny") and
  exact_actions("data.aws_iam_policy_document.results_bucket"; "DenyControlDeletion"; ["s3:DeleteObject", "s3:DeleteObjectVersion"]) and
  exact_condition("data.aws_iam_policy_document.results_bucket"; "DenyControlWritesWithoutConditionalCreate"; "Null"; "s3:if-none-match"; ["true"]) and
  exact_condition("data.aws_iam_policy_document.results_bucket"; "DenyControlOverwrite"; "StringNotEquals"; "s3:if-none-match"; ["*"]) and
  exact_condition("data.aws_iam_policy_document.results_bucket"; "DenyLocalReceiptHandoffWithoutConditionalCreate"; "Null"; "s3:if-none-match"; ["true"]) and
  exact_condition("data.aws_iam_policy_document.results_bucket"; "DenyLocalReceiptHandoffOverwrite"; "StringNotEquals"; "s3:if-none-match"; ["*"]) and

  sids("data.aws_iam_policy_document.scheduler_boundary") == ["TerminateTaggedDemoRunner"] and
  exact_actions("data.aws_iam_policy_document.scheduler_boundary"; "TerminateTaggedDemoRunner"; ["ec2:TerminateInstances"]) and
  statement("data.aws_iam_policy_document.scheduler_boundary"; "TerminateTaggedDemoRunner").condition[0].variable.constant_value == "ec2:ResourceTag/Project" and

  (planned("aws_iam_role.deployer").assume_role_policy | fromjson).Statement[0].Principal.AWS == binding.deployer_principal and
  config("data.aws_iam_policy_document.receipt_publisher_assume").expressions.statement[0].principals[0].identifiers.references == [
    "aws_iam_role.deployer.arn",
    "aws_iam_role.deployer"
  ]
' "$PLAN_JSON" >/dev/null || fail 'IAM configuration violates the closed Task B policy contract'

if [[ "${AWS_PLATFORM_IAM_VALIDATION_ONLY:-0}" != "1" ]]; then
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

    if AWS_PLATFORM_IAM_VALIDATION_ONLY=1 "$0" "$mutated_plan" "$mutated_receipt" >/dev/null 2>&1; then
      fail "validator accepted negative mutation: ${case_name}"
    fi
  }

  verify_rejected_mutation remove-state-deny \
    '(.configuration.root_module.resources[] | select(.address == "data.aws_iam_policy_document.runtime_boundary") | .expressions.statement) |= map(select(.sid.constant_value != "DenyStateStorage"))'
  verify_rejected_mutation weaken-control-delete \
    '(.configuration.root_module.resources[] | select(.address == "data.aws_iam_policy_document.results_bucket") | .expressions.statement[] | select(.sid.constant_value == "DenyControlDeletion") | .effect.constant_value) = "Allow"'
  verify_rejected_mutation broaden-publisher-read \
    '(.configuration.root_module.resources[] | select(.address == "data.aws_iam_policy_document.receipt_publisher") | .expressions.statement[] | select(.sid.constant_value == "ReadBoundedRunnerEvidence") | .resources.references) += ["/runs/*/results/*"]'
fi

printf 'test-aws-platform-iam-contract: PASS\n'
