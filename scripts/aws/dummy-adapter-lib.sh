#!/usr/bin/env bash

[[ -n "${BASH_VERSION:-}" ]] || {
  printf 'aws-dummy-adapter: ERROR: Bash is required\n' >&2
  return 2 2>/dev/null || exit 2
}

readonly AWS_DUMMY_SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly AWS_DUMMY_REPOSITORY_ROOT="$(cd -- "${AWS_DUMMY_SCRIPT_DIRECTORY}/../.." && pwd -P)"
readonly AWS_DUMMY_CANONICAL_ROOT="${AWS_DUMMY_REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke"

aws_dummy_fail() {
  printf 'aws-dummy-adapter: ERROR: %s\n' "$1" >&2
  exit 2
}

aws_dummy_require_command() {
  command -v "$1" >/dev/null 2>&1 || aws_dummy_fail "required command is missing: $1"
}

aws_dummy_require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || aws_dummy_fail "${name} is required"
}

aws_dummy_require_sha256() {
  local name="$1"
  [[ "${!name:-}" =~ ^[0-9a-f]{64}$ ]] || aws_dummy_fail "${name} must be a lower-case SHA-256"
}

aws_dummy_require_file() {
  local name="$1"
  local path="${!name:-}"
  [[ "$path" == /* && "$path" != /tmp/* ]] ||
    aws_dummy_fail "${name} must be an absolute durable path outside /tmp"
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] ||
    aws_dummy_fail "${name} must name a non-empty regular non-symlink file"
}

aws_dummy_require_deployment() {
  [[ "${DEPLOYMENT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$ ]] ||
    aws_dummy_fail 'DEPLOYMENT_ID is required and invalid'
}

aws_dummy_file_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

aws_dummy_prepare_fresh_evidence_directory() {
  aws_dummy_require_env AWS_EVIDENCE_DIRECTORY
  [[ "$AWS_EVIDENCE_DIRECTORY" == /* && "$AWS_EVIDENCE_DIRECTORY" != /tmp/* ]] ||
    aws_dummy_fail 'AWS_EVIDENCE_DIRECTORY must be an absolute durable path outside /tmp'
  case "$AWS_EVIDENCE_DIRECTORY/" in
    "$AWS_DUMMY_REPOSITORY_ROOT"/*)
      aws_dummy_fail 'AWS_EVIDENCE_DIRECTORY must be outside the repository'
      ;;
  esac
  if [[ -e "$AWS_EVIDENCE_DIRECTORY" ]]; then
    [[ -d "$AWS_EVIDENCE_DIRECTORY" && ! -L "$AWS_EVIDENCE_DIRECTORY" ]] ||
      aws_dummy_fail 'AWS_EVIDENCE_DIRECTORY exists but is not a non-symlink directory'
    [[ -z "$(find "$AWS_EVIDENCE_DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
      aws_dummy_fail 'AWS_EVIDENCE_DIRECTORY must be empty'
  else
    mkdir -p -- "$AWS_EVIDENCE_DIRECTORY"
  fi
  chmod 0700 -- "$AWS_EVIDENCE_DIRECTORY"
  umask 077
}

aws_dummy_load_scope() {
  if [[ -z "${AWS_PROFILE:-}" || -z "${AWS_ACCOUNT_ID:-}" || -z "${AWS_REGION:-}" ]]; then
    if [[ -n "${CLOUD_ENV_FILE:-}" || -f "${AWS_DUMMY_REPOSITORY_ROOT}/.env" ]]; then
      # shellcheck disable=SC1091
      source "${AWS_DUMMY_REPOSITORY_ROOT}/scripts/load-cloud-env.sh" aws >/dev/null
    fi
  fi
  aws_dummy_require_env AWS_PROFILE
  [[ "${AWS_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || aws_dummy_fail 'AWS_ACCOUNT_ID is required and invalid'
  [[ "${AWS_REGION:-}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] ||
    aws_dummy_fail 'AWS_REGION is required and invalid'
  export AWS_PAGER=''
}

aws_dummy_aws() {
  command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager "$@" --output json
}

aws_dummy_verify_common_bytes() {
  local expected_output_sha256
  aws_dummy_require_sha256 PACKAGE_LOCK_SHA256
  aws_dummy_require_sha256 IMAGE_SOURCE_MANIFEST_SHA256
  aws_dummy_require_sha256 RUN_SPEC_SHA256
  aws_dummy_require_sha256 INPUT_SHA256
  [[ "${OCI_MANIFEST_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    aws_dummy_fail 'OCI_MANIFEST_DIGEST is required and invalid'
  [[ "$(aws_dummy_file_sha256 "${AWS_DUMMY_CANONICAL_ROOT}/requirements.lock")" == "$PACKAGE_LOCK_SHA256" ]] ||
    aws_dummy_fail 'PACKAGE_LOCK_SHA256 does not match the accepted common file'
  [[ "$(aws_dummy_file_sha256 "${AWS_DUMMY_CANONICAL_ROOT}/image-source-manifest.json")" == "$IMAGE_SOURCE_MANIFEST_SHA256" ]] ||
    aws_dummy_fail 'IMAGE_SOURCE_MANIFEST_SHA256 does not match the accepted common file'
  [[ "$(aws_dummy_file_sha256 "${AWS_DUMMY_CANONICAL_ROOT}/run-spec.example.json")" == "$RUN_SPEC_SHA256" ]] ||
    aws_dummy_fail 'RUN_SPEC_SHA256 does not match the accepted common file'
  [[ "$(aws_dummy_file_sha256 "${AWS_DUMMY_CANONICAL_ROOT}/fixtures/synthetic-input.parquet")" == "$INPUT_SHA256" ]] ||
    aws_dummy_fail 'INPUT_SHA256 does not match the accepted common file'
  expected_output_sha256="$(aws_dummy_file_sha256 "${AWS_DUMMY_CANONICAL_ROOT}/expected-output.json")"
  [[ "$(jq -er '.expected_output_policy_sha256' "${AWS_DUMMY_CANONICAL_ROOT}/run-spec.example.json")" == "$expected_output_sha256" ]] ||
    aws_dummy_fail 'accepted run spec no longer binds the expected-output policy'
  "${AWS_DUMMY_REPOSITORY_ROOT}/scripts/oci/verify-image-source-manifest.sh" >/dev/null ||
    aws_dummy_fail 'accepted image source manifest verification failed'
}

aws_dummy_require_task_b_evidence() {
  for evidence_name in AWS_TASK_B_REVIEW AWS_TASK_B_ACCEPTANCE AWS_PLATFORM_OUTPUTS; do
    aws_dummy_require_file "$evidence_name"
  done
  [[ "$(jq -er '.status' "$AWS_TASK_B_REVIEW")" == 'SAVED_PLAN_READY_FOR_EXACT_APPLY_REVIEW' ]] ||
    aws_dummy_fail 'AWS_TASK_B_REVIEW status is invalid'
  [[ "$(jq -er '.status' "$AWS_TASK_B_ACCEPTANCE")" == 'TASK_B_ACCEPTED' ]] ||
    aws_dummy_fail 'AWS_TASK_B_ACCEPTANCE status is invalid'
  [[ "$(jq -er '.binding.aws_account_id' "$AWS_TASK_B_REVIEW")" == "$AWS_ACCOUNT_ID" ]] ||
    aws_dummy_fail 'Task B evidence account differs from AWS_ACCOUNT_ID'
  [[ "$(jq -er '.binding.aws_region' "$AWS_TASK_B_REVIEW")" == "$AWS_REGION" ]] ||
    aws_dummy_fail 'Task B evidence region differs from AWS_REGION'
}

aws_dummy_write_sha256s() {
  local directory="$1"
  (
    cd -- "$directory"
    find . -type f ! -name SHA256SUMS -printf '%P\n' |
      sort |
      while IFS= read -r file_name; do
        sha256sum "$file_name"
      done >SHA256SUMS
  )
}

aws_dummy_emit_command_result() {
  local output_path="$1"
  local command_name="$2"
  local deployment_json="$3"
  local root_kind_json="$4"
  local check_id="$5"
  local summary="$6"
  shift 6
  local artifacts_json='[]'
  local artifact_path artifact_sha256 artifact_bytes
  for artifact_path in "$@"; do
    [[ -f "$artifact_path" && ! -L "$artifact_path" ]] ||
      aws_dummy_fail "command-result artifact is invalid: ${artifact_path}"
    artifact_sha256="$(aws_dummy_file_sha256 "$artifact_path")"
    artifact_bytes="$(wc -c <"$artifact_path")"
    artifacts_json="$(jq -c \
      --arg path "$artifact_path" \
      --arg sha256 "$artifact_sha256" \
      --argjson bytes "$artifact_bytes" \
      '. + [{path:$path, bytes:$bytes, sha256:$sha256}]' <<<"$artifacts_json")"
  done
  jq -cn \
    --arg command "$command_name" \
    --arg account_id "$AWS_ACCOUNT_ID" \
    --arg region "$AWS_REGION" \
    --arg check_id "$check_id" \
    --arg summary "$summary" \
    --arg generated_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson deployment_id "$deployment_json" \
    --argjson root_kind "$root_kind_json" \
    --argjson artifacts "$artifacts_json" '
    {
      schema_version:"1.0.0",
      command:$command,
      provider:"aws",
      status:"pass",
      exit_code:0,
      generated_at_utc:$generated_at_utc,
      deployment_id:$deployment_id,
      scope:{account_id:$account_id, region:$region, root_kind:$root_kind},
      checks:[{id:$check_id, status:"pass", summary:$summary}],
      artifacts:$artifacts,
      warnings:[],
      errors:[]
    }
  ' >"$output_path"
  "${AWS_DUMMY_REPOSITORY_ROOT}/scripts/validate-command-result.sh" "$output_path" >/dev/null ||
    aws_dummy_fail 'generated command result violates the accepted Goal 02 contract'
}
