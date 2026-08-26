#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'validate-aws-platform-iam-simulation: %s\n' "$1" >&2
  exit 1
}

if (($# != 2)); then
  printf 'usage: %s TASK_B_PLAN_REVIEW_RECEIPT_JSON AWS_PROFILE\n' "$0" >&2
  exit 2
fi

readonly REVIEW_RECEIPT="$1"
readonly PROFILE="$2"

for command_name in aws jq; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: ${command_name}"
done

[[ -f "$REVIEW_RECEIPT" ]] || fail "review receipt does not exist: ${REVIEW_RECEIPT}"
jq -e '.status == "SAVED_PLAN_READY_FOR_EXACT_APPLY_REVIEW"' "$REVIEW_RECEIPT" >/dev/null ||
  fail 'review receipt is not the accepted Task B saved-plan review schema/status'

readonly ACCOUNT_ID="$(jq -er '.binding.aws_account_id' "$REVIEW_RECEIPT")"
readonly REGION="$(jq -er '.binding.aws_region' "$REVIEW_RECEIPT")"
readonly PROJECT_NAME="$(jq -er '.binding.project_name' "$REVIEW_RECEIPT")"
readonly RESOURCE_PREFIX="$(jq -er '.binding.resource_prefix' "$REVIEW_RECEIPT")"
readonly STATE_BUCKET="$(jq -er '.binding.state_bucket' "$REVIEW_RECEIPT")"
readonly PLATFORM_BACKEND_KEY="$(jq -er '.binding.platform_backend_key' "$REVIEW_RECEIPT")"
readonly DATA_BUCKET="$(jq -er '.binding.data_bucket' "$REVIEW_RECEIPT")"
readonly RESULTS_BUCKET="$(jq -er '.binding.results_bucket' "$REVIEW_RECEIPT")"
readonly ECR_REPOSITORY="$(jq -er '.binding.ecr_repository' "$REVIEW_RECEIPT")"
readonly DEPLOYER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${RESOURCE_PREFIX}-tofu-deployer"
readonly PUBLISHER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${RESOURCE_PREFIX}-receipt-publisher"
readonly RUNTIME_BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${RESOURCE_PREFIX}-runtime-boundary"
readonly SCHEDULER_BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${RESOURCE_PREFIX}-scheduler-boundary"
readonly RUNNER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${RESOURCE_PREFIX}-run-contract-test"
readonly OTHER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/not-${RESOURCE_PREFIX}-runner"

export AWS_PAGER=""

aws_read() {
  command aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@" --output json
}

identity_json="$(aws_read sts get-caller-identity)"
jq -e --arg account "$ACCOUNT_ID" '.Account == $account' <<<"$identity_json" >/dev/null ||
  fail 'AWS caller account does not match the reviewed binding'

get_managed_policy_document() {
  local policy_arn="$1"
  local policy_json version_id
  policy_json="$(aws_read iam get-policy --policy-arn "$policy_arn")"
  version_id="$(jq -er '.Policy.DefaultVersionId' <<<"$policy_json")"
  aws_read iam get-policy-version --policy-arn "$policy_arn" --version-id "$version_id" | jq -ec '.PolicyVersion.Document'
}

simulate_principal() {
  local action="$1"
  local resource="$2"
  shift 2
  aws_read iam simulate-principal-policy \
    --policy-source-arn "$DEPLOYER_ROLE_ARN" \
    --action-names "$action" \
    --resource-arns "$resource" \
    "$@" | jq -er '.EvaluationResults[0].EvalDecision'
}

simulate_custom() {
  local policy_json="$1"
  local action="$2"
  local resource="$3"
  shift 3
  aws_read iam simulate-custom-policy \
    --policy-input-list "$policy_json" \
    --action-names "$action" \
    --resource-arns "$resource" \
    "$@" | jq -er '.EvaluationResults[0].EvalDecision'
}

expect_decision() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "${label}: expected ${expected}, received ${actual}"
}

expect_decision allowed \
  "$(simulate_principal s3:GetObject "arn:aws:s3:::${STATE_BUCKET}/aws/${ACCOUNT_ID}/${REGION}/runner/contract-test.tfstate")" \
  'deployer runner-state read'
expect_decision implicitDeny \
  "$(simulate_principal s3:GetObject "arn:aws:s3:::${STATE_BUCKET}/${PLATFORM_BACKEND_KEY}")" \
  'deployer platform-state read'
expect_decision allowed \
  "$(simulate_principal iam:CreateRole "$RUNNER_ROLE_ARN" \
    --context-entries "ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=${RUNTIME_BOUNDARY_ARN},ContextKeyType=arn")" \
  'bounded runner-role creation'
expect_decision implicitDeny \
  "$(simulate_principal iam:CreateRole "$OTHER_ROLE_ARN" \
    --context-entries "ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=${RUNTIME_BOUNDARY_ARN},ContextKeyType=arn")" \
  'non-runner role creation'
expect_decision implicitDeny \
  "$(simulate_principal iam:CreateRole "$RUNNER_ROLE_ARN" \
    --context-entries "ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=arn:aws:iam::${ACCOUNT_ID}:policy/not-accepted,ContextKeyType=arn")" \
  'runner-role creation with wrong boundary'
expect_decision allowed \
  "$(simulate_principal iam:PassRole "$RUNNER_ROLE_ARN" \
    --context-entries 'ContextKeyName=iam:PassedToService,ContextKeyValues=ec2.amazonaws.com,ContextKeyType=string')" \
  'pass runner role to EC2'
expect_decision implicitDeny \
  "$(simulate_principal iam:PassRole "$PUBLISHER_ROLE_ARN" \
    --context-entries 'ContextKeyName=iam:PassedToService,ContextKeyValues=ec2.amazonaws.com,ContextKeyType=string')" \
  'pass receipt publisher role to EC2'

run_instances_allowed_json="$(aws_read iam simulate-principal-policy \
  --policy-source-arn "$DEPLOYER_ROLE_ARN" \
  --action-names ec2:RunInstances \
  --resource-arns \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/i-00000000000000000" \
    "arn:aws:ec2:${REGION}::image/ami-00000000000000000" \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:security-group/sg-00000000000000000" \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:subnet/subnet-00000000000000000" \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:network-interface/eni-00000000000000000" \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:volume/vol-00000000000000000" \
  --resource-handling-option EC2-VPC-EBS \
  --context-entries "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=${PROJECT_NAME},ContextKeyType=string")"
expect_decision allowed "$(jq -er '.EvaluationResults[0].EvalDecision' <<<"$run_instances_allowed_json")" 'tagged EC2 launch'

run_instances_denied_json="$(aws_read iam simulate-principal-policy \
  --policy-source-arn "$DEPLOYER_ROLE_ARN" \
  --action-names ec2:RunInstances \
  --resource-arns \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/i-00000000000000000" \
    "arn:aws:ec2:${REGION}::image/ami-00000000000000000" \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:security-group/sg-00000000000000000" \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:subnet/subnet-00000000000000000" \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:network-interface/eni-00000000000000000" \
    "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:volume/vol-00000000000000000" \
  --resource-handling-option EC2-VPC-EBS)"
expect_decision implicitDeny "$(jq -er '.EvaluationResults[0].EvalDecision' <<<"$run_instances_denied_json")" 'untagged EC2 launch'

runtime_boundary_json="$(get_managed_policy_document "$RUNTIME_BOUNDARY_ARN")"
expect_decision allowed \
  "$(simulate_custom "$runtime_boundary_json" s3:GetObject "arn:aws:s3:::${DATA_BUCKET}/example")" \
  'runtime data read'
expect_decision explicitDeny \
  "$(simulate_custom "$runtime_boundary_json" s3:GetObject "arn:aws:s3:::${STATE_BUCKET}/example")" \
  'runtime state read'
expect_decision explicitDeny \
  "$(simulate_custom "$runtime_boundary_json" sts:AssumeRole "$PUBLISHER_ROLE_ARN")" \
  'runtime publisher assumption'
expect_decision implicitDeny \
  "$(simulate_custom "$runtime_boundary_json" iam:CreateRole '*')" \
  'runtime infrastructure mutation'
expect_decision allowed \
  "$(simulate_custom "$runtime_boundary_json" ecr:BatchGetImage "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPOSITORY}")" \
  'runtime ECR pull'
expect_decision allowed \
  "$(simulate_custom "$runtime_boundary_json" s3:PutObject "arn:aws:s3:::${RESULTS_BUCKET}/runs/contract-test/results/output.json" \
    --context-entries 'ContextKeyName=aws:PrincipalTag/deployment_id,ContextKeyValues=contract-test,ContextKeyType=string')" \
  'runtime own-result write'
expect_decision explicitDeny \
  "$(simulate_custom "$runtime_boundary_json" s3:PutObject "arn:aws:s3:::${RESULTS_BUCKET}/control/receipts/contract-test/completion.v1.json" \
    --context-entries 'ContextKeyName=s3:if-none-match,ContextKeyValues=*,ContextKeyType=string')" \
  'runtime final-receipt write'

scheduler_boundary_json="$(get_managed_policy_document "$SCHEDULER_BOUNDARY_ARN")"
expect_decision allowed \
  "$(simulate_custom "$scheduler_boundary_json" ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/i-00000000000000000" \
    --context-entries "ContextKeyName=ec2:ResourceTag/Project,ContextKeyValues=${PROJECT_NAME},ContextKeyType=string")" \
  'scheduler tagged termination'
expect_decision implicitDeny \
  "$(simulate_custom "$scheduler_boundary_json" ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/i-00000000000000000" \
    --context-entries 'ContextKeyName=ec2:ResourceTag/Project,ContextKeyValues=other-project,ContextKeyType=string')" \
  'scheduler other-project termination'

publisher_simulation_json="$(aws_read iam simulate-principal-policy \
  --policy-source-arn "$PUBLISHER_ROLE_ARN" \
  --action-names s3:GetObject \
  --resource-arns "arn:aws:s3:::${RESULTS_BUCKET}/runs/contract-test/control-input/execution-receipt.local.json")"
expect_decision allowed "$(jq -er '.EvaluationResults[0].EvalDecision' <<<"$publisher_simulation_json")" 'publisher local-receipt read'

publisher_simulation_json="$(aws_read iam simulate-principal-policy \
  --policy-source-arn "$PUBLISHER_ROLE_ARN" \
  --action-names s3:GetObject \
  --resource-arns "arn:aws:s3:::${RESULTS_BUCKET}/runs/contract-test/results/output.json")"
expect_decision implicitDeny "$(jq -er '.EvaluationResults[0].EvalDecision' <<<"$publisher_simulation_json")" 'publisher arbitrary-result read'

publisher_simulation_json="$(aws_read iam simulate-principal-policy \
  --policy-source-arn "$PUBLISHER_ROLE_ARN" \
  --action-names s3:PutObject \
  --resource-arns "arn:aws:s3:::${RESULTS_BUCKET}/control/receipts/contract-test/completion.v1.json" \
  --context-entries 'ContextKeyName=s3:if-none-match,ContextKeyValues=*,ContextKeyType=string')"
expect_decision allowed "$(jq -er '.EvaluationResults[0].EvalDecision' <<<"$publisher_simulation_json")" 'publisher conditional final-receipt write'

publisher_simulation_json="$(aws_read iam simulate-principal-policy \
  --policy-source-arn "$PUBLISHER_ROLE_ARN" \
  --action-names s3:DeleteObject \
  --resource-arns "arn:aws:s3:::${RESULTS_BUCKET}/control/receipts/contract-test/completion.v1.json")"
expect_decision implicitDeny "$(jq -er '.EvaluationResults[0].EvalDecision' <<<"$publisher_simulation_json")" 'publisher final-receipt deletion'

printf 'validate-aws-platform-iam-simulation: PASS\n'
