#!/usr/bin/env bash
# Backend-disabled init/validate of every AWS root plus the offline target and storage suites.
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

"${REPOSITORY_ROOT}/scripts/aws/validate-scaffold.sh" >/dev/null
bash "${REPOSITORY_ROOT}/tests/aws/test-workspace-target.sh" >/dev/null

test_cache_root="${XDG_CACHE_HOME:-/var/tmp}/ray-terraform-tests-${UID}"
mkdir -p "$test_cache_root"
chmod 700 "$test_cache_root"
temporary_console_directory="$(mktemp -d "${test_cache_root}/aws-scaffold.XXXXXX")"
trap 'rm -rf -- "$temporary_console_directory"' EXIT

for root_name in bootstrap/workspace platform platform/workspace runner/workspace; do
  jq -e --raw-input --slurp 'length > 0' \
    <"${REPOSITORY_ROOT}/infra/aws/${root_name}/.terraform.lock.hcl" >/dev/null

  terraform_data_directory="${temporary_console_directory}/terraform-${root_name//\//-}"
  mkdir -p "$terraform_data_directory"
  TF_DATA_DIR="$terraform_data_directory" tofu \
    -chdir="${REPOSITORY_ROOT}/infra/aws/${root_name}" init \
    -backend=false -input=false -lockfile=readonly -no-color >/dev/null
  TF_DATA_DIR="$terraform_data_directory" tofu \
    -chdir="${REPOSITORY_ROOT}/infra/aws/${root_name}" validate -no-color >/dev/null
done

AWS_STORAGE_PLATFORM_TF_DATA_DIR="${temporary_console_directory}/terraform-platform" \
  AWS_STORAGE_RUNNER_TF_DATA_DIR="${temporary_console_directory}/terraform-runner-workspace" \
  bash "${REPOSITORY_ROOT}/tests/aws/test-workspace-storage.sh"

printf 'test-aws-scaffold: PASS\n'
