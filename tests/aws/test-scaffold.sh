#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly VALID_AWS_REQUEST="${REPOSITORY_ROOT}/shared/contracts/fixtures/valid-aws.json"

"${REPOSITORY_ROOT}/scripts/aws/validate-scaffold.sh" >/dev/null
"${REPOSITORY_ROOT}/tests/aws/test-platform-live-validator.sh" >/dev/null
"${REPOSITORY_ROOT}/tests/aws/test-dummy-adapter.sh" >/dev/null
bash "${REPOSITORY_ROOT}/tests/aws/test-workspace-target.sh" >/dev/null

test_cache_root="${XDG_CACHE_HOME:-/var/tmp}/ray-terraform-tests-${UID}"
mkdir -p "$test_cache_root"
chmod 700 "$test_cache_root"
temporary_console_directory="$(mktemp -d "${test_cache_root}/aws-scaffold.XXXXXX")"
trap 'rm -rf -- "$temporary_console_directory"' EXIT

for root_name in bootstrap platform runner; do
  jq -e --raw-input --slurp 'length > 0' \
    <"${REPOSITORY_ROOT}/infra/aws/${root_name}/.terraform.lock.hcl" >/dev/null

  terraform_data_directory="${temporary_console_directory}/terraform-${root_name}"
  mkdir -p "$terraform_data_directory"
  TF_DATA_DIR="$terraform_data_directory" tofu \
    -chdir="${REPOSITORY_ROOT}/infra/aws/${root_name}" init \
    -backend=false -input=false -lockfile=readonly -no-color >/dev/null
  TF_DATA_DIR="$terraform_data_directory" tofu \
    -chdir="${REPOSITORY_ROOT}/infra/aws/${root_name}" validate -no-color >/dev/null
done

expected_request_sha256="$("${REPOSITORY_ROOT}/scripts/hash-runner-request.sh" "$VALID_AWS_REQUEST")"
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
grep -F '/runs/*/results/result-manifest.json' <<<"$publisher_policy" >/dev/null || {
  printf 'test-aws-scaffold: publisher cannot read the exact canonical result manifest\n' >&2
  exit 1
}
if grep -F '/runs/*/results/*' <<<"$publisher_policy" >/dev/null; then
  printf 'test-aws-scaffold: publisher has broad result-object read access\n' >&2
  exit 1
fi

rg -F '/usr/bin/systemctl enable --now "$service_name"' \
  "${REPOSITORY_ROOT}/infra/aws/runner/templates/user-data.sh.tftpl" >/dev/null || {
  printf 'test-aws-scaffold: runner does not start its reviewed Docker and SSM services\n' >&2
  exit 1
}

printf 'test-aws-scaffold: PASS\n'
