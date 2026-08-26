#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly AWS_ROOT="${REPOSITORY_ROOT}/infra/aws"

fail() {
  printf 'validate-aws-scaffold: %s\n' "$1" >&2
  exit 1
}

for command_name in rg tofu; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: ${command_name}"
done

for root_name in bootstrap platform runner; do
  root_path="${AWS_ROOT}/${root_name}"
  [[ -d "$root_path" ]] || fail "missing AWS root: ${root_name}"
  [[ -f "${root_path}/versions.tf" ]] || fail "missing versions.tf in ${root_name}"
  [[ -f "${root_path}/provider.tf" ]] || fail "missing provider.tf in ${root_name}"
  [[ -f "${root_path}/.terraform.lock.hcl" ]] || fail "missing dependency lock file in ${root_name}"

  rg -F 'required_version = "= 1.12.3"' "${root_path}/versions.tf" >/dev/null ||
    fail "${root_name} does not pin OpenTofu 1.12.3"
  rg -F 'source  = "hashicorp/aws"' "${root_path}/versions.tf" >/dev/null ||
    fail "${root_name} does not declare hashicorp/aws"
  rg -F 'version = "= 6.61.0"' "${root_path}/versions.tf" >/dev/null ||
    fail "${root_name} does not pin hashicorp/aws 6.61.0"
  rg -F 'version     = "6.61.0"' "${root_path}/.terraform.lock.hcl" >/dev/null ||
    fail "${root_name} lock file does not select hashicorp/aws 6.61.0"
  rg -F 'allowed_account_ids = [var.aws_account_id]' "${root_path}/provider.tf" >/dev/null ||
    fail "${root_name} provider is not bound to the reviewed account"
done

if rg -n '^\s*backend\s+"' "${AWS_ROOT}/bootstrap" --glob '*.tf' >/dev/null; then
  fail 'bootstrap must use local state and may not configure its own backend'
fi
for root_name in platform runner; do
  rg -F 'backend "s3" {}' "${AWS_ROOT}/${root_name}/versions.tf" >/dev/null ||
    fail "${root_name} must declare an externally configured S3 backend"
  rg -F 'use_lockfile = true' "${AWS_ROOT}/${root_name}/backend.hcl.example" >/dev/null ||
    fail "${root_name} backend example must enable native lock files"
done

if rg -n '^\s*module\s+"' "$AWS_ROOT" --glob '*.tf' >/dev/null; then
  fail 'AWS roots must remain flat and may not hide resources in modules'
fi

if rg -n '(access_key|secret_key|session_token|shared_credentials_file)\s*=' "$AWS_ROOT" --glob '*.tf' --glob '*.hcl' >/dev/null; then
  fail 'static credential configuration is forbidden'
fi

if find "$AWS_ROOT" -type f \( -name '*.tfstate' -o -name '*.tfstate.*' -o -name '*.tfplan' \) -print -quit | grep -q .; then
  fail 'state and saved plans may not exist inside the repository AWS roots'
fi

rg -F 'prevent_destroy = true' "${AWS_ROOT}/bootstrap/main.tf" >/dev/null || fail 'state bucket lacks destroy protection'
rg -F 'block_public_acls       = true' "${AWS_ROOT}/bootstrap/main.tf" >/dev/null || fail 'state bucket lacks public-access protection'
rg -F 'status = "Enabled"' "${AWS_ROOT}/bootstrap/main.tf" >/dev/null || fail 'state bucket lacks versioning'
rg -F 'aws:SecureTransport' "${AWS_ROOT}/bootstrap/main.tf" >/dev/null || fail 'state bucket lacks TLS-only policy'

rg -F 'image_tag_mutability = "IMMUTABLE"' "${AWS_ROOT}/platform/storage.tf" >/dev/null || fail 'ECR is not immutable'
rg -F 'DenyControlWritesFromOtherPrincipals' "${AWS_ROOT}/platform/storage.tf" >/dev/null || fail 'receipt control prefix is not isolated'
rg -F 'DenyControlDeletion' "${AWS_ROOT}/platform/storage.tf" >/dev/null || fail 'receipt control objects are not deletion-protected'
rg -F 's3:DeleteObjectVersion' "${AWS_ROOT}/platform/storage.tf" >/dev/null || fail 'receipt control object versions are not deletion-protected'
rg -F 's3:if-none-match' "${AWS_ROOT}/platform/storage.tf" >/dev/null || fail 'receipt publication is not conditional-create only'
rg -F 'DenyReceiptPublisherAssumption' "${AWS_ROOT}/platform/iam.tf" >/dev/null || fail 'runtime boundary does not deny publisher assumption'
rg -F 'ReadBoundedRunnerEvidence' "${AWS_ROOT}/platform/iam.tf" >/dev/null || fail 'publisher cannot read bounded runner evidence'
rg -F 'ec2:DescribeInstances' "${AWS_ROOT}/platform/iam.tf" >/dev/null || fail 'publisher cannot read runner lifecycle facts'
rg -F 'scheduler:GetSchedule' "${AWS_ROOT}/platform/iam.tf" >/dev/null || fail 'publisher cannot independently read the runner deadline schedule'
rg -F 'DenyLocalReceiptHandoffOverwrite' "${AWS_ROOT}/platform/storage.tf" >/dev/null || fail 'local receipt handoff is not create-only'
rg -F 'platform_contract_sha256 = sha256(jsonencode(local.platform_contract))' "${AWS_ROOT}/platform/outputs.tf" >/dev/null || fail 'platform does not canonically hash its closed binding'
if rg -n '^\s*ingress\s*\{' "${AWS_ROOT}/platform" --glob '*.tf' >/dev/null; then
  fail 'runner security group may not define inbound access'
fi

rg -F 'variable "runner_request"' "${AWS_ROOT}/runner/variables.tf" >/dev/null ||
  fail 'runner is missing the closed common request object'
for field_name in \
  schema_version deployment_id provider oci_repository oci_digest run_spec_uri \
  run_spec_sha256 run_spec_object_version resource_profile capacity_mode \
  maximum_runtime_minutes
do
  rg -e "^[[:space:]]*${field_name}[[:space:]]*=" "${AWS_ROOT}/runner/variables.tf" >/dev/null ||
    fail "runner request object is missing common field: ${field_name}"
done

rg -F 'http_tokens                 = "required"' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner does not require IMDSv2'
rg -F 'http_put_response_hop_limit = 2' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'container cannot obtain its temporary IMDSv2 workload credentials'
rg -F 'encrypted   = true' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner root disk is not encrypted'
rg -F 'aws_scheduler_schedule' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner lacks an independent AWS deadline'
rg -F 'ec2:StopInstances' "${AWS_ROOT}/runner/iam.tf" >/dev/null || fail 'deadline role is not limited to stopping the runner'
rg -F 'latest_apply_at_utc    = timeadd(var.started_at_utc, "5m")' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner latest-apply boundary is not derived at five minutes'
rg -F 'timecmp(timestamp(), var.started_at_utc) >= 0 && timecmp(timestamp(), local.latest_apply_at_utc) <= 0' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner lacks a bounded start/latest-apply window'
if rg -n '^variable "latest_apply_at_utc"' "${AWS_ROOT}/runner/variables.tf" >/dev/null; then
  fail 'runner may not accept an arbitrary latest-apply boundary'
fi
rg -F 'request_sha256         = sha256(jsonencode(var.runner_request))' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner does not derive the canonical request hash'
rg -F 'platform_contract_sha256 = sha256(jsonencode(var.platform_contract))' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner does not recompute the platform binding hash'
rg -F 'jsonencode(var.platform_contract) == jsonencode(local.bound_platform_contract)' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner does not bind its platform resource inputs'
if rg -n '^variable "(?:request_sha256|platform_contract_sha256)"' "${AWS_ROOT}/runner/variables.tf" >/dev/null; then
  fail 'runner may not accept caller-supplied request or platform hashes'
fi
rg -F 'DenyReceiptPublisherAssumption' "${AWS_ROOT}/runner/iam.tf" >/dev/null || fail 'runner can potentially assume the publisher role'
rg -F 'ConditionallyCreateLocalReceiptHandoff' "${AWS_ROOT}/runner/iam.tf" >/dev/null || fail 'runner cannot create its exact local receipt handoff'
rg -F 'control-input/execution-receipt.local.json' "${AWS_ROOT}/runner/main.tf" >/dev/null || fail 'runner does not bind the exact local receipt handoff key'
rg -F -- "--if-none-match '*'" "${AWS_ROOT}/runner/templates/user-data.sh.tftpl" >/dev/null || fail 'local receipt handoff is not conditionally created'
rg -F 'MAXIMUM_BOOTSTRAP_LOG_BYTES=1048576' "${AWS_ROOT}/runner/templates/user-data.sh.tftpl" >/dev/null || fail 'persisted bootstrap log is not bounded to one MiB'
rg -F 'trap finalize EXIT' "${AWS_ROOT}/runner/templates/user-data.sh.tftpl" >/dev/null || fail 'bootstrap failures do not enter the finalization path'
rg -F 'successful guest execution produced no local receipt' "${AWS_ROOT}/runner/templates/user-data.sh.tftpl" >/dev/null || fail 'successful guest execution does not fail closed when its local receipt is absent'
rg -F 'bounded bootstrap log upload failed' "${AWS_ROOT}/runner/templates/user-data.sh.tftpl" >/dev/null || fail 'bounded bootstrap-log upload failures are not surfaced'
rg -F 'mark_evidence_failure' "${AWS_ROOT}/runner/templates/user-data.sh.tftpl" >/dev/null || fail 'evidence failures do not preserve prior nonzero guest/bootstrap status'

tofu fmt -check -recursive "$AWS_ROOT" >/dev/null || fail 'AWS OpenTofu formatting is not canonical'

printf 'validate-aws-scaffold: PASS\n'
