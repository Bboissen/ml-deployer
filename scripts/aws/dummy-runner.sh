#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIRECTORY}/dummy-adapter-lib.sh"

if (($# != 1)); then
  aws_dummy_fail 'usage: scripts/aws/dummy-runner.sh plan|apply|observe|destroy-plan|destroy|post-destroy-check'
fi
readonly OPERATION="$1"
case "$OPERATION" in plan|apply|observe|destroy-plan|destroy|post-destroy-check) ;; *) aws_dummy_fail "unsupported runner operation: ${OPERATION}" ;; esac

aws_dummy_require_command aws
aws_dummy_require_command base64
aws_dummy_require_command jq
aws_dummy_require_command tofu
aws_dummy_require_command xxd
aws_dummy_require_deployment
aws_dummy_load_scope
aws_dummy_require_task_b_evidence

readonly STATE_BUCKET="$(jq -er '.binding.state_bucket' "$AWS_TASK_B_REVIEW")"
readonly RESULTS_BUCKET="$(jq -er '.binding.results_bucket' "$AWS_TASK_B_REVIEW")"
readonly DATA_BUCKET="$(jq -er '.binding.data_bucket' "$AWS_TASK_B_REVIEW")"
readonly PROJECT_NAME="$(jq -er '.binding.project_name' "$AWS_TASK_B_REVIEW")"
readonly RESOURCE_PREFIX="$(jq -er '.binding.resource_prefix' "$AWS_TASK_B_REVIEW")"
readonly ECR_REPOSITORY="$(jq -er '.ecr_repository_url.value' "$AWS_PLATFORM_OUTPUTS")"
readonly RUNNER_BACKEND_KEY="aws/${AWS_ACCOUNT_ID}/${AWS_REGION}/runner/${DEPLOYMENT_ID}.tfstate"
readonly RUN_SPEC_KEY="run-specs/${DEPLOYMENT_ID}/${RUN_SPEC_SHA256:-missing}.json"
readonly INPUT_KEY="fixtures/tool-complete-dummy/${INPUT_SHA256:-missing}.parquet"

require_runner_plan_directory() {
  aws_dummy_require_env AWS_RUNNER_PLAN_DIRECTORY
  [[ "$AWS_RUNNER_PLAN_DIRECTORY" == /* && "$AWS_RUNNER_PLAN_DIRECTORY" != /tmp/* ]] ||
    aws_dummy_fail 'AWS_RUNNER_PLAN_DIRECTORY must be an absolute durable path outside /tmp'
  [[ -d "$AWS_RUNNER_PLAN_DIRECTORY" && ! -L "$AWS_RUNNER_PLAN_DIRECTORY" ]] ||
    aws_dummy_fail 'AWS_RUNNER_PLAN_DIRECTORY is not a non-symlink directory'
  for required in plan-metadata.json source/infra/aws/runner/versions.tf tofu-data; do
    [[ -e "${AWS_RUNNER_PLAN_DIRECTORY}/${required}" ]] ||
      aws_dummy_fail "runner plan directory is incomplete: ${required}"
  done
  jq -e --arg deployment "$DEPLOYMENT_ID" --arg backend_key "$RUNNER_BACKEND_KEY" \
    '.schema_version == "1.0.0" and .deployment_id == $deployment and .backend_key == $backend_key' \
    "${AWS_RUNNER_PLAN_DIRECTORY}/plan-metadata.json" >/dev/null ||
    aws_dummy_fail 'runner plan metadata does not match this deployment'
}

require_runner_outputs() {
  aws_dummy_require_file AWS_RUNNER_OUTPUTS
  jq -e --arg deployment "$DEPLOYMENT_ID" '
    .deployment_id.value == $deployment and .provider.value == "aws"
    and (.runner_id.value | test("^i-[0-9a-f]{8,17}$"))
  ' "$AWS_RUNNER_OUTPUTS" >/dev/null || aws_dummy_fail 'AWS_RUNNER_OUTPUTS does not match this deployment'
}

verify_remote_publications() {
  local ecr_digest run_spec_version input_checksum run_spec_checksum
  aws_dummy_require_sha256 INPUT_SHA256
  aws_dummy_require_sha256 RUN_SPEC_SHA256
  [[ "${OCI_MANIFEST_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || aws_dummy_fail 'OCI_MANIFEST_DIGEST is invalid'
  aws_dummy_require_env AWS_RUN_SPEC_VERSION_ID
  ecr_digest="$(aws_dummy_aws ecr describe-images --repository-name "${ECR_REPOSITORY#*/}" \
    --image-ids "imageDigest=${OCI_MANIFEST_DIGEST}" | jq -er '.imageDetails[0].imageDigest')"
  [[ "$ecr_digest" == "$OCI_MANIFEST_DIGEST" ]] || aws_dummy_fail 'reviewed OCI digest is absent from ECR'
  run_spec_version="$(aws_dummy_aws s3api head-object --bucket "$RESULTS_BUCKET" --key "$RUN_SPEC_KEY" \
    --version-id "$AWS_RUN_SPEC_VERSION_ID" | jq -er '.VersionId')"
  [[ "$run_spec_version" == "$AWS_RUN_SPEC_VERSION_ID" ]] || aws_dummy_fail 'reviewed run-spec version is absent'
  run_spec_checksum="$(aws_dummy_aws s3api head-object --bucket "$RESULTS_BUCKET" --key "$RUN_SPEC_KEY" \
    --version-id "$AWS_RUN_SPEC_VERSION_ID" --checksum-mode ENABLED | jq -er '.ChecksumSHA256')"
  input_checksum="$(aws_dummy_aws s3api head-object --bucket "$DATA_BUCKET" --key "$INPUT_KEY" \
    --checksum-mode ENABLED | jq -er '.ChecksumSHA256')"
  [[ "$run_spec_checksum" == "$(printf '%s' "$RUN_SPEC_SHA256" | xxd -r -p | base64 -w0)" ]] ||
    aws_dummy_fail 'remote run-spec checksum does not match the accepted bytes'
  [[ "$input_checksum" == "$(printf '%s' "$INPUT_SHA256" | xxd -r -p | base64 -w0)" ]] ||
    aws_dummy_fail 'remote synthetic-input checksum does not match the accepted bytes'
}

if [[ "$OPERATION" == plan ]]; then
  aws_dummy_verify_common_bytes
  aws_dummy_require_file AWS_PREFLIGHT_SUMMARY
  jq -e --arg deployment "$DEPLOYMENT_ID" '
    .status == "pass" and .scope.deployment_id == $deployment
    and ([.checks[]] | all(. == true or . == false))
    and .checks.publisher_manifest_read == true
    and .checks.publisher_arbitrary_results_read == false
  ' "$AWS_PREFLIGHT_SUMMARY" >/dev/null || aws_dummy_fail 'AWS_PREFLIGHT_SUMMARY is not a passing current readiness gate'
  aws_dummy_require_env AWS_AMI_ID
  [[ "$AWS_AMI_ID" =~ ^ami-[0-9a-f]{8,17}$ ]] || aws_dummy_fail 'AWS_AMI_ID is invalid'
  aws_dummy_require_env AWS_RUN_SPEC_VERSION_ID
  [[ "$AWS_RUN_SPEC_VERSION_ID" =~ ^[^[:cntrl:][:space:]]{1,512}$ ]] || aws_dummy_fail 'AWS_RUN_SPEC_VERSION_ID is invalid'
  aws_dummy_require_env AWS_STARTED_AT_UTC
  aws_dummy_require_env AWS_DEADLINE_UTC
  [[ "$AWS_STARTED_AT_UTC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    aws_dummy_fail 'AWS_STARTED_AT_UTC is invalid'
  [[ "$AWS_DEADLINE_UTC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    aws_dummy_fail 'AWS_DEADLINE_UTC is invalid'
  readonly MAXIMUM_RUNTIME_MINUTES="${AWS_MAXIMUM_RUNTIME_MINUTES:-60}"
  [[ "$MAXIMUM_RUNTIME_MINUTES" =~ ^[0-9]+$ ]] &&
    ((10#$MAXIMUM_RUNTIME_MINUTES >= 15 && 10#$MAXIMUM_RUNTIME_MINUTES <= 720)) ||
    aws_dummy_fail 'AWS_MAXIMUM_RUNTIME_MINUTES must be 15 through 720'
  started_epoch="$(date -u -d "$AWS_STARTED_AT_UTC" +%s)" || aws_dummy_fail 'AWS_STARTED_AT_UTC is not a real timestamp'
  deadline_epoch="$(date -u -d "$AWS_DEADLINE_UTC" +%s)" || aws_dummy_fail 'AWS_DEADLINE_UTC is not a real timestamp'
  now_epoch="$(date -u +%s)"
  ((started_epoch >= now_epoch + 600)) || aws_dummy_fail 'AWS_STARTED_AT_UTC must leave at least ten minutes for exact-plan review'
  ((deadline_epoch > started_epoch + 300 && deadline_epoch <= started_epoch + 10#$MAXIMUM_RUNTIME_MINUTES * 60)) ||
    aws_dummy_fail 'AWS_DEADLINE_UTC violates the reviewed apply/runtime window'
  verify_remote_publications
  aws_dummy_aws s3api list-object-versions --bucket "$STATE_BUCKET" --prefix "$RUNNER_BACKEND_KEY" \
    | jq -e --arg key "$RUNNER_BACKEND_KEY" '
        ([.Versions[]? | select(.Key == $key)] | length) == 0
        and ([.DeleteMarkers[]? | select(.Key == $key)] | length) == 0
      ' >/dev/null || aws_dummy_fail 'runner backend key has history and cannot be reused'
  aws_dummy_prepare_fresh_evidence_directory

  readonly SEALED_ROOT="${AWS_EVIDENCE_DIRECTORY}/source"
  readonly SEALED_RUNNER_ROOT="${SEALED_ROOT}/infra/aws/runner"
  readonly TOFU_DATA_DIRECTORY="${AWS_EVIDENCE_DIRECTORY}/tofu-data"
  mkdir -p -- "${SEALED_RUNNER_ROOT}/templates" "${SEALED_ROOT}/shared/bootstrap" "$TOFU_DATA_DIRECTORY"
  cp -- "${AWS_DUMMY_REPOSITORY_ROOT}/infra/aws/runner/"*.tf "${SEALED_RUNNER_ROOT}/"
  cp -- "${AWS_DUMMY_REPOSITORY_ROOT}/infra/aws/runner/.terraform.lock.hcl" "${SEALED_RUNNER_ROOT}/"
  cp -- "${AWS_DUMMY_REPOSITORY_ROOT}/infra/aws/runner/templates/user-data.sh.tftpl" "${SEALED_RUNNER_ROOT}/templates/"
  cp -- "${AWS_DUMMY_REPOSITORY_ROOT}/shared/bootstrap/guest-runner.sh" \
    "${AWS_DUMMY_REPOSITORY_ROOT}/shared/bootstrap/deadline-marker.sh" "${SEALED_ROOT}/shared/bootstrap/"

  jq -cn \
    --arg deployment_id "$DEPLOYMENT_ID" --arg repository "$ECR_REPOSITORY" \
    --arg oci_digest "$OCI_MANIFEST_DIGEST" \
    --arg run_spec_uri "s3://${RESULTS_BUCKET}/${RUN_SPEC_KEY}" \
    --arg run_spec_sha256 "$RUN_SPEC_SHA256" --arg run_spec_version "$AWS_RUN_SPEC_VERSION_ID" \
    --argjson maximum_runtime "$MAXIMUM_RUNTIME_MINUTES" '
    {schema_version:"1.0.0", deployment_id:$deployment_id, provider:"aws",
      oci_repository:$repository, oci_digest:$oci_digest, run_spec_uri:$run_spec_uri,
      run_spec_sha256:$run_spec_sha256, run_spec_object_version:$run_spec_version,
      resource_profile:"smoke", capacity_mode:"standard", maximum_runtime_minutes:$maximum_runtime}
  ' >"${AWS_EVIDENCE_DIRECTORY}/runner-request.json"
  "${AWS_DUMMY_REPOSITORY_ROOT}/scripts/validate-runner-request.sh" \
    "${AWS_EVIDENCE_DIRECTORY}/runner-request.json" >/dev/null
  readonly REQUEST_SHA256="$("${AWS_DUMMY_REPOSITORY_ROOT}/scripts/hash-runner-request.sh" "${AWS_EVIDENCE_DIRECTORY}/runner-request.json")"
  readonly PLATFORM_CONTRACT_SHA256="$(jq -er '.platform_contract_sha256.value' "$AWS_PLATFORM_OUTPUTS")"

  jq -n \
    --slurpfile request "${AWS_EVIDENCE_DIRECTORY}/runner-request.json" \
    --slurpfile outputs "$AWS_PLATFORM_OUTPUTS" \
    --slurpfile review "$AWS_TASK_B_REVIEW" \
    --arg aws_region "$AWS_REGION" --arg aws_account_id "$AWS_ACCOUNT_ID" \
    --arg project_name "$PROJECT_NAME" --arg resource_prefix "$RESOURCE_PREFIX" \
    --arg ami_id "$AWS_AMI_ID" --arg backend_key "$RUNNER_BACKEND_KEY" \
    --arg started_at_utc "$AWS_STARTED_AT_UTC" --arg deadline_utc "$AWS_DEADLINE_UTC" '
    {
      runner_request:$request[0], platform_contract:$outputs[0].platform_contract.value,
      aws_region:$aws_region, aws_account_id:$aws_account_id,
      project_name:$project_name, resource_prefix:$resource_prefix,
      deployer_role_arn:$outputs[0].deployer_role_arn.value,
      ami_id:$ami_id, subnet_id:$outputs[0].runner_subnet_id.value,
      security_group_id:$outputs[0].runner_security_group_id.value,
      associate_public_ipv4_address:true,
      data_bucket_name:$outputs[0].data_bucket_name.value,
      data_bucket_arn:$outputs[0].data_bucket_arn.value,
      results_bucket_name:$outputs[0].results_bucket_name.value,
      results_bucket_arn:$outputs[0].results_bucket_arn.value,
      ecr_repository_arn:$outputs[0].ecr_repository_arn.value,
      state_bucket_arn:$outputs[0].platform_contract.value.state_bucket_arn,
      runtime_permissions_boundary_arn:$outputs[0].runtime_permissions_boundary_arn.value,
      scheduler_permissions_boundary_arn:$outputs[0].scheduler_permissions_boundary_arn.value,
      receipt_publisher_role_arn:$outputs[0].receipt_publisher_role_arn.value,
      account_scope:$aws_account_id, backend_key:$backend_key,
      backend_bucket_name:$outputs[0].platform_contract.value.state_bucket_name,
      started_at_utc:$started_at_utc, deadline_utc:$deadline_utc,
      tags:$review[0].binding.tags
    }
  ' >"${AWS_EVIDENCE_DIRECTORY}/runner.auto.tfvars.json"
  jq -rn --arg bucket "$STATE_BUCKET" --arg key "$RUNNER_BACKEND_KEY" --arg region "$AWS_REGION" '
    "bucket = \"" + $bucket + "\"\n" +
    "key = \"" + $key + "\"\n" +
    "region = \"" + $region + "\"\n" +
    "encrypt = true\nuse_lockfile = true\n"
  ' >"${AWS_EVIDENCE_DIRECTORY}/backend.hcl"

  export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-/home/user/.cache/opentofu/plugin-cache}"
  [[ -d "$TF_PLUGIN_CACHE_DIR" && "$TF_PLUGIN_CACHE_DIR" != /tmp/* ]] ||
    aws_dummy_fail 'TF_PLUGIN_CACHE_DIR must be an existing durable provider cache outside /tmp'
  TF_DATA_DIR="$TOFU_DATA_DIRECTORY" tofu -chdir="$SEALED_RUNNER_ROOT" init \
    -backend-config="${AWS_EVIDENCE_DIRECTORY}/backend.hcl" -input=false -lockfile=readonly -no-color \
    >"${AWS_EVIDENCE_DIRECTORY}/init.txt"
  TF_DATA_DIR="$TOFU_DATA_DIRECTORY" tofu -chdir="$SEALED_RUNNER_ROOT" validate -no-color \
    >"${AWS_EVIDENCE_DIRECTORY}/validate.txt"
  set +e
  TF_DATA_DIR="$TOFU_DATA_DIRECTORY" tofu -chdir="$SEALED_RUNNER_ROOT" plan \
    -input=false -lock-timeout=60s -no-color \
    -var-file="${AWS_EVIDENCE_DIRECTORY}/runner.auto.tfvars.json" \
    -out="${AWS_EVIDENCE_DIRECTORY}/runner.tfplan" \
    -detailed-exitcode >"${AWS_EVIDENCE_DIRECTORY}/plan.txt" 2>&1
  plan_exit=$?
  set -e
  [[ "$plan_exit" -eq 2 ]] || aws_dummy_fail "runner plan did not produce the exact create delta; exit=${plan_exit}"
  TF_DATA_DIR="$TOFU_DATA_DIRECTORY" tofu -chdir="$SEALED_RUNNER_ROOT" show -json \
    "${AWS_EVIDENCE_DIRECTORY}/runner.tfplan" >"${AWS_EVIDENCE_DIRECTORY}/runner.tfplan.json"
  TF_DATA_DIR="$TOFU_DATA_DIRECTORY" tofu -chdir="$SEALED_RUNNER_ROOT" show -no-color \
    "${AWS_EVIDENCE_DIRECTORY}/runner.tfplan" >"${AWS_EVIDENCE_DIRECTORY}/runner.tfplan.txt"
  jq -e '
    [.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | {address, actions:.change.actions}] as $changes
    | ($changes | length) == 8
    and all($changes[]; .actions == ["create"])
    and ([$changes[].address] | sort) == ([
      "aws_iam_instance_profile.runtime", "aws_iam_role.runtime", "aws_iam_role.scheduler",
      "aws_iam_role_policy.runtime", "aws_iam_role_policy.scheduler",
      "aws_iam_role_policy_attachment.ssm",
      "aws_instance.runner", "aws_scheduler_schedule.deadline"
    ] | sort)
  ' "${AWS_EVIDENCE_DIRECTORY}/runner.tfplan.json" >/dev/null ||
    aws_dummy_fail 'runner plan actions differ from the exact disposable allowlist'
  readonly SAVED_PLAN_SHA256="$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/runner.tfplan")"
  jq -cn \
    --arg created_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg deployment_id "$DEPLOYMENT_ID" --arg account_id "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
    --arg backend_key "$RUNNER_BACKEND_KEY" --arg request_sha256 "$REQUEST_SHA256" \
    --arg platform_contract_sha256 "$PLATFORM_CONTRACT_SHA256" \
    --arg saved_plan_sha256 "$SAVED_PLAN_SHA256" \
    --arg started_at_utc "$AWS_STARTED_AT_UTC" --arg deadline_utc "$AWS_DEADLINE_UTC" '
    {schema_version:"1.0.0", status:"saved_plan_ready_for_exact_apply_review",
      created_at_utc:$created_at_utc, provider:"aws", deployment_id:$deployment_id,
      account_id:$account_id, region:$region, backend_key:$backend_key,
      request_sha256:$request_sha256, platform_contract_sha256:$platform_contract_sha256,
      saved_plan:{file:"runner.tfplan", sha256:$saved_plan_sha256,
        actions:{create:8, update:0, delete:0, replace:0}},
      apply_window:{started_at_utc:$started_at_utc, latest_apply_at_utc:($started_at_utc | fromdateiso8601 + 300 | todateiso8601), deadline_utc:$deadline_utc},
      next_gate:("APPLY EXACT ARTIFACT sha256:" + $saved_plan_sha256 + " FOR aws")}
  ' >"${AWS_EVIDENCE_DIRECTORY}/plan-metadata.json"
  aws_dummy_emit_command_result "${AWS_EVIDENCE_DIRECTORY}/command-result.json" plan \
    "$(jq -Rn --arg v "$DEPLOYMENT_ID" '$v')" '"runner"' aws.runner-plan \
    'Exact eight-resource disposable runner saved plan prepared without apply' \
    "${AWS_EVIDENCE_DIRECTORY}/runner.tfplan" "${AWS_EVIDENCE_DIRECTORY}/runner.tfplan.json" \
    "${AWS_EVIDENCE_DIRECTORY}/plan-metadata.json"
  aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
  jq -cS . "${AWS_EVIDENCE_DIRECTORY}/plan-metadata.json"
  exit 0
fi

if [[ "$OPERATION" == apply ]]; then
  aws_dummy_verify_file_sha256 SAVED_PLAN SAVED_PLAN_SHA256
  aws_dummy_verify_exact_authorization APPLY_AUTHORIZATION apply "$SAVED_PLAN_SHA256"
  plan_directory="$(cd -- "$(dirname -- "$SAVED_PLAN")" && pwd -P)"
  [[ "$SAVED_PLAN" == "${plan_directory}/runner.tfplan" ]] || aws_dummy_fail 'SAVED_PLAN must be the sealed runner.tfplan'
  AWS_RUNNER_PLAN_DIRECTORY="$plan_directory"
  require_runner_plan_directory
  [[ "$(aws_dummy_file_sha256 "$SAVED_PLAN")" == "$(jq -er '.saved_plan.sha256' "${plan_directory}/plan-metadata.json")" ]] ||
    aws_dummy_fail 'saved plan differs from its sealed metadata'
  started_at="$(jq -er '.apply_window.started_at_utc' "${plan_directory}/plan-metadata.json")"
  latest_apply="$(jq -er '.apply_window.latest_apply_at_utc' "${plan_directory}/plan-metadata.json")"
  now_epoch="$(date -u +%s)"
  ((now_epoch >= $(date -u -d "$started_at" +%s) && now_epoch <= $(date -u -d "$latest_apply" +%s))) ||
    aws_dummy_fail 'current time is outside the exact saved-plan apply window; replan and review'
  aws_dummy_aws s3api list-object-versions --bucket "$STATE_BUCKET" --prefix "$RUNNER_BACKEND_KEY" |
    jq -e --arg key "$RUNNER_BACKEND_KEY" '([.Versions[]? | select(.Key == $key)] | length) == 0' >/dev/null ||
    aws_dummy_fail 'runner backend state appeared after plan review'
  aws_dummy_prepare_fresh_evidence_directory
  set +e
  TF_DATA_DIR="${plan_directory}/tofu-data" tofu -chdir="${plan_directory}/source/infra/aws/runner" apply \
    -input=false -lock-timeout=60s -no-color "$SAVED_PLAN" \
    >"${AWS_EVIDENCE_DIRECTORY}/apply.txt" 2>&1
  apply_exit=$?
  set -e
  printf '%s\n' "$apply_exit" >"${AWS_EVIDENCE_DIRECTORY}/apply.exit"
  [[ "$apply_exit" -eq 0 ]] || aws_dummy_fail 'exact runner apply failed; preserve evidence and do not retry automatically'
  TF_DATA_DIR="${plan_directory}/tofu-data" tofu -chdir="${plan_directory}/source/infra/aws/runner" output -json \
    >"${AWS_EVIDENCE_DIRECTORY}/runner-outputs.json"
  aws_dummy_aws s3api head-object --bucket "$STATE_BUCKET" --key "$RUNNER_BACKEND_KEY" \
    >"${AWS_EVIDENCE_DIRECTORY}/runner-state-object.json"
  jq -cn --arg applied_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg deployment_id "$DEPLOYMENT_ID" --arg saved_plan_sha256 "$(aws_dummy_file_sha256 "$SAVED_PLAN")" \
    --arg outputs_sha256 "$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/runner-outputs.json")" '
    {schema_version:"1.0.0", status:"applied", provider:"aws", deployment_id:$deployment_id,
      applied_at_utc:$applied_at_utc, saved_plan_sha256:$saved_plan_sha256,
      runner_outputs_sha256:$outputs_sha256, automatic_retry:false}
  ' >"${AWS_EVIDENCE_DIRECTORY}/apply-record.json"
  cp -- "$APPLY_AUTHORIZATION" "${AWS_EVIDENCE_DIRECTORY}/apply-authorization.json"
  aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
  jq -cS . "${AWS_EVIDENCE_DIRECTORY}/apply-record.json"
  exit 0
fi

if [[ "$OPERATION" == observe ]]; then
  require_runner_outputs
  aws_dummy_prepare_fresh_evidence_directory
  runner_id="$(jq -er '.runner_id.value' "$AWS_RUNNER_OUTPUTS")"
  aws_dummy_aws ec2 describe-instances --instance-ids "$runner_id" >"${AWS_EVIDENCE_DIRECTORY}/instance.json"
  aws_dummy_aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${runner_id}" \
    >"${AWS_EVIDENCE_DIRECTORY}/ssm.json"
  aws_dummy_aws scheduler get-schedule --name "$(jq -er '.provider_deadline_control.value | split("/")[-1]' "$AWS_RUNNER_OUTPUTS")" \
    >"${AWS_EVIDENCE_DIRECTORY}/schedule.json"
  aws_dummy_aws s3api list-objects-v2 --bucket "$RESULTS_BUCKET" --prefix "runs/${DEPLOYMENT_ID}/" \
    >"${AWS_EVIDENCE_DIRECTORY}/run-objects.json"
  aws_dummy_aws s3api list-objects-v2 --bucket "$RESULTS_BUCKET" --prefix "control/receipts/${DEPLOYMENT_ID}/" \
    >"${AWS_EVIDENCE_DIRECTORY}/receipt-objects.json"
  jq -cn --slurpfile instance "${AWS_EVIDENCE_DIRECTORY}/instance.json" \
    --slurpfile ssm "${AWS_EVIDENCE_DIRECTORY}/ssm.json" \
    --slurpfile objects "${AWS_EVIDENCE_DIRECTORY}/run-objects.json" \
    --arg observed_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg deployment_id "$DEPLOYMENT_ID" '
    {schema_version:"1.0.0", observed_at_utc:$observed_at_utc, provider:"aws", deployment_id:$deployment_id,
      point_in_time_liveness:{instance_state:$instance[0].Reservations[0].Instances[0].State.Name,
        ssm_managed:(($ssm[0].InstanceInformationList | length) == 1)},
      run_object_count:$objects[0].KeyCount, terminal_acceptance:false}
  ' >"${AWS_EVIDENCE_DIRECTORY}/observation.json"
  aws_dummy_emit_command_result "${AWS_EVIDENCE_DIRECTORY}/command-result.json" observe \
    "$(jq -Rn --arg v "$DEPLOYMENT_ID" '$v')" '"runner"' aws.observe \
    'One bounded point-in-time AWS observation completed; this is not terminal acceptance' \
    "${AWS_EVIDENCE_DIRECTORY}/observation.json"
  aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
  jq -cS . "${AWS_EVIDENCE_DIRECTORY}/observation.json"
  exit 0
fi

if [[ "$OPERATION" == destroy-plan ]]; then
  require_runner_plan_directory
  require_runner_outputs
  aws_dummy_prepare_fresh_evidence_directory
  source_root="${AWS_RUNNER_PLAN_DIRECTORY}/source/infra/aws/runner"
  tf_data="${AWS_RUNNER_PLAN_DIRECTORY}/tofu-data"
  TF_DATA_DIR="$tf_data" tofu -chdir="$source_root" state list >"${AWS_EVIDENCE_DIRECTORY}/state-list-before.txt"
  sed '/^data\./d' "${AWS_EVIDENCE_DIRECTORY}/state-list-before.txt" \
    >"${AWS_EVIDENCE_DIRECTORY}/managed-state-list-before.txt"
  [[ "$(wc -l <"${AWS_EVIDENCE_DIRECTORY}/managed-state-list-before.txt")" -eq 8 ]] ||
    aws_dummy_fail 'runner state does not contain the exact eight-resource lifecycle'
  grep -Fxq 'aws_instance.runner' "${AWS_EVIDENCE_DIRECTORY}/managed-state-list-before.txt" ||
    aws_dummy_fail 'runner state does not contain the sealed EC2 instance'
  runner_id="$(jq -er '.runner_id.value' "$AWS_RUNNER_OUTPUTS")"
  aws_dummy_aws ec2 describe-instances --instance-ids "$runner_id" \
    >"${AWS_EVIDENCE_DIRECTORY}/destroy-instance-before.json"
  instance_already_terminated=false
  [[ "$(jq -er '.Reservations[0].Instances[0].State.Name' \
    "${AWS_EVIDENCE_DIRECTORY}/destroy-instance-before.json")" == terminated ]] &&
    instance_already_terminated=true
  set +e
  TF_DATA_DIR="$tf_data" tofu -chdir="$source_root" plan -destroy -input=false -lock-timeout=60s -no-color \
    -var-file="${AWS_RUNNER_PLAN_DIRECTORY}/runner.auto.tfvars.json" \
    -out="${AWS_EVIDENCE_DIRECTORY}/destroy.tfplan" -detailed-exitcode \
    >"${AWS_EVIDENCE_DIRECTORY}/destroy-plan.txt" 2>&1
  destroy_plan_exit=$?
  set -e
  [[ "$destroy_plan_exit" -eq 2 ]] || aws_dummy_fail 'destroy plan did not produce the exact runner-only delete delta'
  TF_DATA_DIR="$tf_data" tofu -chdir="$source_root" show -json "${AWS_EVIDENCE_DIRECTORY}/destroy.tfplan" \
    >"${AWS_EVIDENCE_DIRECTORY}/destroy.tfplan.json"
  jq -e --argjson instance_already_terminated "$instance_already_terminated" '
    [.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | {address, actions:.change.actions}] as $changes
    | ([
      "aws_iam_instance_profile.runtime", "aws_iam_role.runtime", "aws_iam_role.scheduler",
      "aws_iam_role_policy.runtime", "aws_iam_role_policy.scheduler",
      "aws_iam_role_policy_attachment.ssm",
      "aws_instance.runner", "aws_scheduler_schedule.deadline"
    ] | if $instance_already_terminated then . - ["aws_instance.runner"] else . end) as $allowlist
    | ($changes | length) == ($allowlist | length)
    and all($changes[]; .actions == ["delete"])
    and ([$changes[].address] | sort) == ($allowlist | sort)
  ' "${AWS_EVIDENCE_DIRECTORY}/destroy.tfplan.json" >/dev/null ||
    aws_dummy_fail 'destroy plan is not limited to the exact runner resource allowlist'
  destroy_sha="$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/destroy.tfplan")"
  destroy_delete_count="$(jq '[.resource_changes[] | select(.change.actions == ["delete"])] | length' \
    "${AWS_EVIDENCE_DIRECTORY}/destroy.tfplan.json")"
  jq -cn --arg created_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg deployment_id "$DEPLOYMENT_ID" \
    --arg runner_plan_directory "$AWS_RUNNER_PLAN_DIRECTORY" --arg saved_plan_sha256 "$destroy_sha" \
    --argjson delete_count "$destroy_delete_count" '
    {schema_version:"1.0.0", status:"destroy_plan_ready_for_exact_review", provider:"aws",
      created_at_utc:$created_at_utc, deployment_id:$deployment_id,
      runner_plan_directory:$runner_plan_directory,
      saved_plan:{file:"destroy.tfplan", sha256:$saved_plan_sha256,
        actions:{create:0, update:0, delete:$delete_count, replace:0}},
      next_gate:("DESTROY EXACT ARTIFACT sha256:" + $saved_plan_sha256 + " FOR aws")}
  ' >"${AWS_EVIDENCE_DIRECTORY}/destroy-plan-metadata.json"
  aws_dummy_emit_command_result "${AWS_EVIDENCE_DIRECTORY}/command-result.json" destroy \
    "$(jq -Rn --arg v "$DEPLOYMENT_ID" '$v')" '"runner"' aws.destroy-plan \
    'Exact eight-resource runner-only saved destroy plan prepared without apply' \
    "${AWS_EVIDENCE_DIRECTORY}/destroy.tfplan" "${AWS_EVIDENCE_DIRECTORY}/destroy.tfplan.json" \
    "${AWS_EVIDENCE_DIRECTORY}/destroy-plan-metadata.json"
  aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
  jq -cS . "${AWS_EVIDENCE_DIRECTORY}/destroy-plan-metadata.json"
  exit 0
fi

if [[ "$OPERATION" == destroy ]]; then
  aws_dummy_verify_file_sha256 SAVED_PLAN SAVED_PLAN_SHA256
  aws_dummy_verify_exact_authorization DESTROY_AUTHORIZATION destroy "$SAVED_PLAN_SHA256"
  destroy_dir="$(cd -- "$(dirname -- "$SAVED_PLAN")" && pwd -P)"
  [[ "$SAVED_PLAN" == "${destroy_dir}/destroy.tfplan" ]] || aws_dummy_fail 'SAVED_PLAN must be the sealed destroy.tfplan'
  metadata="${destroy_dir}/destroy-plan-metadata.json"
  [[ -f "$metadata" && ! -L "$metadata" ]] || aws_dummy_fail 'destroy plan metadata is missing'
  AWS_RUNNER_PLAN_DIRECTORY="$(jq -er '.runner_plan_directory' "$metadata")"
  require_runner_plan_directory
  [[ "$(aws_dummy_file_sha256 "$SAVED_PLAN")" == "$(jq -er '.saved_plan.sha256' "$metadata")" ]] ||
    aws_dummy_fail 'destroy plan differs from its sealed metadata'
  aws_dummy_prepare_fresh_evidence_directory
  set +e
  TF_DATA_DIR="${AWS_RUNNER_PLAN_DIRECTORY}/tofu-data" \
    tofu -chdir="${AWS_RUNNER_PLAN_DIRECTORY}/source/infra/aws/runner" apply \
      -input=false -lock-timeout=60s -no-color "$SAVED_PLAN" \
      >"${AWS_EVIDENCE_DIRECTORY}/destroy.txt" 2>&1
  destroy_exit=$?
  set -e
  printf '%s\n' "$destroy_exit" >"${AWS_EVIDENCE_DIRECTORY}/destroy.exit"
  [[ "$destroy_exit" -eq 0 ]] || aws_dummy_fail 'exact runner destroy failed; preserve evidence and do not retry automatically'
  cp -- "$DESTROY_AUTHORIZATION" "${AWS_EVIDENCE_DIRECTORY}/destroy-authorization.json"
  jq -cn --arg destroyed_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg deployment_id "$DEPLOYMENT_ID" \
    --arg saved_plan_sha256 "$(aws_dummy_file_sha256 "$SAVED_PLAN")" '
    {schema_version:"1.0.0", status:"destroy_applied", provider:"aws", deployment_id:$deployment_id,
      destroyed_at_utc:$destroyed_at_utc, saved_plan_sha256:$saved_plan_sha256, automatic_retry:false}
  ' >"${AWS_EVIDENCE_DIRECTORY}/destroy-record.json"
  aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
  jq -cS . "${AWS_EVIDENCE_DIRECTORY}/destroy-record.json"
  exit 0
fi

require_runner_plan_directory
require_runner_outputs
aws_dummy_prepare_fresh_evidence_directory
runner_id="$(jq -er '.runner_id.value' "$AWS_RUNNER_OUTPUTS")"
runtime_role="$(jq -er '.workload_identity.value | split("/")[-1]' "$AWS_RUNNER_OUTPUTS")"
schedule_name="$(jq -er '.provider_deadline_control.value | split("/")[-1]' "$AWS_RUNNER_OUTPUTS")"
set +e
aws_dummy_aws ec2 describe-instances --instance-ids "$runner_id" >"${AWS_EVIDENCE_DIRECTORY}/instance.json" 2>"${AWS_EVIDENCE_DIRECTORY}/instance.stderr"
instance_exit=$?
aws_dummy_aws iam get-role --role-name "$runtime_role" >"${AWS_EVIDENCE_DIRECTORY}/runtime-role.json" 2>"${AWS_EVIDENCE_DIRECTORY}/runtime-role.stderr"
role_exit=$?
aws_dummy_aws scheduler get-schedule --name "$schedule_name" >"${AWS_EVIDENCE_DIRECTORY}/schedule.json" 2>"${AWS_EVIDENCE_DIRECTORY}/schedule.stderr"
schedule_exit=$?
set -e
require_exact_not_found() {
  local exit_code="$1"
  local stderr_path="$2"
  local expected_code="$3"
  local resource_label="$4"
  ((exit_code != 0)) || return 0
  grep -Fq "(${expected_code})" "$stderr_path" ||
    aws_dummy_fail "${resource_label} lookup failed without the exact ${expected_code} absence response"
}
require_exact_not_found "$instance_exit" "${AWS_EVIDENCE_DIRECTORY}/instance.stderr" \
  InvalidInstanceID.NotFound 'runner instance'
require_exact_not_found "$role_exit" "${AWS_EVIDENCE_DIRECTORY}/runtime-role.stderr" \
  NoSuchEntity 'runtime role'
require_exact_not_found "$schedule_exit" "${AWS_EVIDENCE_DIRECTORY}/schedule.stderr" \
  ResourceNotFoundException 'deadline schedule'
if ((instance_exit != 0)); then printf '{}\n' >"${AWS_EVIDENCE_DIRECTORY}/instance.json"; fi
if ((role_exit != 0)); then printf '{}\n' >"${AWS_EVIDENCE_DIRECTORY}/runtime-role.json"; fi
if ((schedule_exit != 0)); then printf '{}\n' >"${AWS_EVIDENCE_DIRECTORY}/schedule.json"; fi
TF_DATA_DIR="${AWS_RUNNER_PLAN_DIRECTORY}/tofu-data" \
  tofu -chdir="${AWS_RUNNER_PLAN_DIRECTORY}/source/infra/aws/runner" state list \
  >"${AWS_EVIDENCE_DIRECTORY}/state-list-after.txt"
state_empty=false
[[ ! -s "${AWS_EVIDENCE_DIRECTORY}/state-list-after.txt" ]] && state_empty=true
runner_absent=false
if ((instance_exit != 0)); then
  runner_absent=true
elif jq -e '[.Reservations[].Instances[]] | length == 1 and all(.State.Name == "terminated")' \
  "${AWS_EVIDENCE_DIRECTORY}/instance.json" >/dev/null; then
  runner_absent=true
fi
identities_absent=false
((role_exit != 0 && schedule_exit != 0)) && identities_absent=true
aws_dummy_aws s3api head-bucket --bucket "$STATE_BUCKET" >"${AWS_EVIDENCE_DIRECTORY}/state-bucket.json"
aws_dummy_aws s3api head-bucket --bucket "$DATA_BUCKET" >"${AWS_EVIDENCE_DIRECTORY}/data-bucket.json"
aws_dummy_aws s3api head-bucket --bucket "$RESULTS_BUCKET" >"${AWS_EVIDENCE_DIRECTORY}/results-bucket.json"
aws_dummy_aws ecr describe-repositories --repository-names "${ECR_REPOSITORY#*/}" \
  >"${AWS_EVIDENCE_DIRECTORY}/ecr-repository.json"
persistent_retained=true
[[ "$runner_absent" == true && "$identities_absent" == true && "$state_empty" == true ]] ||
  aws_dummy_fail 'post-destroy runner resources or runner state remain'
jq -cn --arg checked_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg deployment_id "$DEPLOYMENT_ID" \
  --argjson runner_absent "$runner_absent" --argjson runner_state_absent "$state_empty" \
  --argjson persistent_storage_retained "$persistent_retained" '
  {schema_version:"1.0.0", checked_at_utc:$checked_at_utc, provider:"aws", deployment_id:$deployment_id,
    runner_absent:$runner_absent, runner_state_absent:$runner_state_absent,
    persistent_storage_retained:$persistent_storage_retained,
    provider_api_evidence_sha256:"pending-after-file-finalization"}
' >"${AWS_EVIDENCE_DIRECTORY}/post-destroy.pending.json"
jq -cn --slurpfile instance "${AWS_EVIDENCE_DIRECTORY}/instance.json" \
  --slurpfile role "${AWS_EVIDENCE_DIRECTORY}/runtime-role.json" \
  --slurpfile schedule "${AWS_EVIDENCE_DIRECTORY}/schedule.json" \
  --rawfile instance_stderr "${AWS_EVIDENCE_DIRECTORY}/instance.stderr" \
  --rawfile role_stderr "${AWS_EVIDENCE_DIRECTORY}/runtime-role.stderr" \
  --rawfile schedule_stderr "${AWS_EVIDENCE_DIRECTORY}/schedule.stderr" \
  --argjson instance_api_exit "$instance_exit" --argjson role_api_exit "$role_exit" --argjson schedule_api_exit "$schedule_exit" \
  '{instance_api_exit:$instance_api_exit, role_api_exit:$role_api_exit, schedule_api_exit:$schedule_api_exit,
    absence_classification:{
      instance:(if $instance_api_exit == 0 then "terminated" else "InvalidInstanceID.NotFound" end),
      runtime_role:(if $role_api_exit == 0 then "present" else "NoSuchEntity" end),
      deadline_schedule:(if $schedule_api_exit == 0 then "present" else "ResourceNotFoundException" end)},
    instance:(if $instance_api_exit == 0 then $instance[0] else null end),
    runtime_role:(if $role_api_exit == 0 then $role[0] else null end),
    deadline_schedule:(if $schedule_api_exit == 0 then $schedule[0] else null end),
    api_errors:{instance:$instance_stderr, runtime_role:$role_stderr, deadline_schedule:$schedule_stderr}}' \
  >"${AWS_EVIDENCE_DIRECTORY}/post-destroy-provider-api.json"
api_sha="$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/post-destroy-provider-api.json")"
jq --arg sha "$api_sha" '.provider_api_evidence_sha256 = $sha' \
  "${AWS_EVIDENCE_DIRECTORY}/post-destroy.pending.json" >"${AWS_EVIDENCE_DIRECTORY}/post-destroy.json"
aws_dummy_emit_command_result "${AWS_EVIDENCE_DIRECTORY}/command-result.json" destroy \
  "$(jq -Rn --arg v "$DEPLOYMENT_ID" '$v')" '"runner"' aws.post-destroy \
  'Runner resources and state are reconciled while persistent AWS storage and ECR remain' \
  "${AWS_EVIDENCE_DIRECTORY}/post-destroy.json" "${AWS_EVIDENCE_DIRECTORY}/post-destroy-provider-api.json"
aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
jq -cS . "${AWS_EVIDENCE_DIRECTORY}/post-destroy.json"
