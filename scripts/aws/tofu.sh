#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tofu_bin="${TOFU:-tofu}"
runtime_dir="$repo_root/.aws-runtime"
roots=(bootstrap storage network training-node spot-runner)

die() { printf 'aws-tofu: %s\n' "$*" >&2; exit 1; }

require_root() {
  case "$1" in
    bootstrap|storage|network|training-node|spot-runner) ;;
    *) die "unsupported root: $1" ;;
  esac
}

root_path() {
  printf '%s/tofu/aws/%s' "$repo_root" "$1"
}

validate_all() {
  local root path
  for root in "${roots[@]}"; do
    path="$(root_path "$root")"
    "$tofu_bin" -chdir="$path" init -backend=false -input=false
    "$tofu_bin" -chdir="$path" validate
  done
}

init_root() {
  local root="$1" path
  require_root "$root"
  path="$(root_path "$root")"
  if [[ "$root" == bootstrap ]]; then
    "$tofu_bin" -chdir="$path" init -backend=false -input=false
  else
    [[ "${AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || die 'AWS_ACCOUNT_ID must be an exact 12-digit account ID'
    [[ "${AWS_REGION:-}" == us-east-1 ]] || die 'AWS_REGION must be us-east-1 for V0'
    [[ -n "${AWS_STATE_BUCKET:-}" ]] || die 'AWS_STATE_BUCKET is required'
    "$tofu_bin" -chdir="$path" init -input=false -reconfigure \
      -backend-config="bucket=${AWS_STATE_BUCKET}" \
      -backend-config="key=aws/${root}/terraform.tfstate" \
      -backend-config="region=${AWS_REGION}" \
      -backend-config="profile=${AWS_PROFILE:-sposhfi-admin}" \
      -backend-config="use_lockfile=true"
  fi
}

plan_root() {
  local root="$1" path plan_file
  require_root "$root"
  [[ "${AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || die 'AWS_ACCOUNT_ID must be an exact 12-digit account ID'
  [[ "${AWS_REGION:-}" == us-east-1 ]] || die 'AWS_REGION must be us-east-1 for V0'
  path="$(root_path "$root")"
  mkdir -p "$runtime_dir/plans"
  chmod 0700 "$runtime_dir" "$runtime_dir/plans"
  plan_file="$runtime_dir/plans/${root}.tfplan"
  "$tofu_bin" -chdir="$path" plan -input=false -out="$plan_file" \
    -var="account_id=${AWS_ACCOUNT_ID}" -var="region=${AWS_REGION}"
  chmod 0600 "$plan_file"
  printf 'saved_plan=%s sha256=%s\n' "$plan_file" "$(sha256sum "$plan_file" | awk '{print $1}')"
}

case "${1:-}" in
  validate-all) validate_all ;;
  init) init_root "${2:?root required}" ;;
  plan) plan_root "${2:?root required}" ;;
  *) die 'usage: tofu.sh <validate-all|init ROOT|plan ROOT>' ;;
esac
