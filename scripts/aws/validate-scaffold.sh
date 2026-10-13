#!/usr/bin/env bash
# Static checks on the AWS OpenTofu roots: pins, flat layout, no credentials, no state, no ingress.
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

for root_name in bootstrap/workspace platform platform/workspace runner/workspace; do
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

rg -F 'backend "local" {}' "${AWS_ROOT}/bootstrap/workspace/versions.tf" >/dev/null ||
  fail 'bootstrap must bind an explicit evidence-local backend'
for root_name in platform platform/workspace runner/workspace; do
  rg -F 'backend "s3" {}' "${AWS_ROOT}/${root_name}/versions.tf" >/dev/null ||
    fail "${root_name} must declare an externally configured S3 backend"
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

if rg -n '^\s*ingress\s*\{' "$AWS_ROOT" --glob '*.tf' >/dev/null; then
  fail 'workspace security groups may not define inbound access'
fi

rg -F 'http_tokens                 = "required"' "${AWS_ROOT}/runner/workspace/main.tf" >/dev/null || fail 'workspace instance does not require IMDSv2'
rg -F 'encrypted             = true' "${AWS_ROOT}/runner/workspace/main.tf" >/dev/null || fail 'workspace root disk is not encrypted'
rg -F 'aws_scheduler_schedule' "${AWS_ROOT}/runner/workspace/main.tf" >/dev/null || fail 'workspace lacks an independent AWS deadline'

tofu fmt -check -recursive "$AWS_ROOT" >/dev/null || fail 'AWS OpenTofu formatting is not canonical'

printf 'validate-aws-scaffold: PASS\n'
