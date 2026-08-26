#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly VALID_AWS_REQUEST="${REPOSITORY_ROOT}/shared/contracts/fixtures/valid-aws.json"

"${REPOSITORY_ROOT}/scripts/aws/validate-scaffold.sh" >/dev/null
"${REPOSITORY_ROOT}/tests/aws/test-platform-live-validator.sh" >/dev/null

for root_name in bootstrap platform runner; do
  jq -e --raw-input --slurp 'length > 0' \
    <"${REPOSITORY_ROOT}/infra/aws/${root_name}/.terraform.lock.hcl" >/dev/null
done

expected_request_sha256="$("${REPOSITORY_ROOT}/scripts/hash-runner-request.sh" "$VALID_AWS_REQUEST")"
temporary_console_directory="$(mktemp -d)"
trap 'rm -rf -- "$temporary_console_directory"' EXIT
request_path_literal="$(jq -Rn --arg value "$VALID_AWS_REQUEST" '$value')"
actual_request_sha256="$({
  printf 'sha256(jsonencode(jsondecode(file(%s))))\n' "$request_path_literal"
} | tofu -chdir="$temporary_console_directory" console | tr -d '"')"
[[ "$actual_request_sha256" == "$expected_request_sha256" ]] || {
  printf 'test-aws-scaffold: OpenTofu jsonencode hash disagrees with normative request hash\n' >&2
  exit 1
}

publisher_policy="$({
  sed -n '/data "aws_iam_policy_document" "receipt_publisher"/,/resource "aws_iam_role_policy" "receipt_publisher"/p' \
    "${REPOSITORY_ROOT}/infra/aws/platform/iam.tf"
})"
if grep -F '/runs/*/results/' <<<"$publisher_policy" >/dev/null; then
  printf 'test-aws-scaffold: publisher must not read results before a canonical manifest path is accepted\n' >&2
  exit 1
fi

printf 'test-aws-scaffold: PASS\n'
