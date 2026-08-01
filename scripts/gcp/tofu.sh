#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOFU_BIN="${TOFU:-tofu}"
STATE_BUCKET="${GCP_STATE_BUCKET:-example-project-tofu-state}"
RUNTIME_DIR="$REPO_ROOT/.gcp-runtime"
ROOTS=(bootstrap storage network training-node)

die() { printf 'gcp-tofu: %s\n' "$*" >&2; exit 1; }
root_path() { printf '%s/tofu/gcp/%s' "$REPO_ROOT" "$1"; }
require_root() {
  case "$1" in bootstrap|storage|network|training-node) ;; *) die "unsupported root: $1" ;; esac
}

prepare_vars() {
  local root="$1"
  export TF_VAR_project_id="${GCP_PROJECT_ID:-example-project}"
  export TF_VAR_region="${GCP_REGION:-us-central1}"
  export TF_VAR_zone="${GCP_ZONE:-us-central1-a}"
  case "$root" in
    bootstrap)
      [[ -n "${GCP_ADMIN_EMAIL:-}" ]] || die 'GCP_ADMIN_EMAIL is required for bootstrap plans'
      export TF_VAR_admin_email="$GCP_ADMIN_EMAIL"
      ;;
    storage)
      [[ -n "${GCP_ADMIN_EMAIL:-}" ]] || die 'GCP_ADMIN_EMAIL is required for storage plans'
      export TF_VAR_admin_email="$GCP_ADMIN_EMAIL"
      ;;
    network)
      [[ -n "${GCP_ADMIN_EMAIL:-}" && -n "${GCP_TRAINING_SERVICE_ACCOUNT:-}" ]] || die 'GCP_ADMIN_EMAIL and GCP_TRAINING_SERVICE_ACCOUNT are required'
      export TF_VAR_admin_email="$GCP_ADMIN_EMAIL"
      export TF_VAR_training_service_account_email="$GCP_TRAINING_SERVICE_ACCOUNT"
      ;;
    training-node)
      [[ -n "${GCP_TRAINING_SERVICE_ACCOUNT:-}" && -n "${GCP_SUBNETWORK_SELF_LINK:-}" ]] || die 'GCP_TRAINING_SERVICE_ACCOUNT and GCP_SUBNETWORK_SELF_LINK are required'
      export TF_VAR_training_service_account_email="$GCP_TRAINING_SERVICE_ACCOUNT"
      export TF_VAR_subnetwork_self_link="$GCP_SUBNETWORK_SELF_LINK"
      export TF_VAR_artifact_bucket_name="${GCP_ARTIFACT_BUCKET:-example-project-artifacts}"
      ;;
  esac
}

init_root() {
  local root="$1" path
  require_root "$root"
  path="$(root_path "$root")"
  if [[ "$root" == bootstrap ]]; then
    umask 077
    mkdir -p "$path/.bootstrap-state"
    chmod 0700 "$path/.bootstrap-state"
    "$TOFU_BIN" -chdir="$path" init -input=false -reconfigure
  else
    [[ -n "${GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT:-}" ]] || die 'GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT is required'
    "$TOFU_BIN" -chdir="$path" init -input=false -reconfigure \
      -backend-config="bucket=$STATE_BUCKET" -backend-config="prefix=gcp/$root" \
      -backend-config="impersonate_service_account=${GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT}"
  fi
}

validate_all() {
  local root path
  for root in "${ROOTS[@]}"; do
    path="$(root_path "$root")"
    "$TOFU_BIN" -chdir="$path" init -backend=false -input=false
    "$TOFU_BIN" -chdir="$path" validate
  done
}

plan_root() {
  local root="$1" operation="$2" path plan_file plan_json profile_args=()
  require_root "$root"
  prepare_vars "$root"
  path="$(root_path "$root")"
  mkdir -p "$RUNTIME_DIR/plans"
  chmod 0700 "$RUNTIME_DIR" "$RUNTIME_DIR/plans"
  plan_file="$RUNTIME_DIR/plans/$root.tfplan"
  plan_json="$plan_file.json"
  if [[ "$root" == training-node ]]; then
    profile_args=(-var="profile_name=${PROFILE:-smoke-free}")
  fi
  "$TOFU_BIN" -chdir="$path" plan -input=false -out="$plan_file" "${profile_args[@]}"
  "$TOFU_BIN" -chdir="$path" show -json "$plan_file" >"$plan_json"
  python3 "$REPO_ROOT/scripts/gcp/plan_policy.py" --operation "$operation" "$plan_json"
  chmod 0600 "$plan_file" "$plan_json"
  printf 'saved_plan=%s sha256=%s\n' "$plan_file" "$(sha256sum "$plan_file" | awk '{print $1}')"
}

destroy_compute() {
  local path
  path="$(root_path training-node)"
  prepare_vars training-node
  printf '%s\n' 'Destroy scope: tofu/gcp/training-node only. Persistent roots are excluded.'
  "$TOFU_BIN" -chdir="$path" destroy -var="profile_name=${PROFILE:-smoke-free}"
}

case "${1:-}" in
  init) init_root "${2:?root required}" ;;
  validate-all) validate_all ;;
  plan) plan_root "${2:?root required}" "${3:?operation required}" ;;
  destroy-compute) destroy_compute ;;
  *) die 'usage: tofu.sh <init ROOT|validate-all|plan ROOT OPERATION|destroy-compute>' ;;
esac
