#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIRECTORY}/dummy-adapter-lib.sh"

if (($# != 0)); then
  aws_dummy_fail 'prepare-dummy-receipt accepts no arguments; use explicit environment variables'
fi
for command_name in aws check-jsonschema jq; do aws_dummy_require_command "$command_name"; done
aws_dummy_require_deployment
aws_dummy_load_scope
aws_dummy_require_task_b_evidence
aws_dummy_require_file AWS_RUNNER_OUTPUTS
aws_dummy_require_file AWS_RUNNER_REQUEST
aws_dummy_prepare_fresh_evidence_directory

"${AWS_DUMMY_REPOSITORY_ROOT}/scripts/validate-runner-request.sh" "$AWS_RUNNER_REQUEST" >/dev/null ||
  aws_dummy_fail 'AWS_RUNNER_REQUEST violates the accepted contract'
readonly SEALED_REQUEST_SHA256="$("${AWS_DUMMY_REPOSITORY_ROOT}/scripts/hash-runner-request.sh" "$AWS_RUNNER_REQUEST")"
jq -e --arg deployment "$DEPLOYMENT_ID" '
  .deployment_id.value == $deployment and .provider.value == "aws"
' "$AWS_RUNNER_OUTPUTS" >/dev/null || aws_dummy_fail 'AWS_RUNNER_OUTPUTS does not match the deployment'
[[ "$(jq -er '.request_sha256.value' "$AWS_RUNNER_OUTPUTS")" == "$SEALED_REQUEST_SHA256" ]] ||
  aws_dummy_fail 'runner outputs do not bind the sealed runner request'

readonly RESULTS_BUCKET="$(jq -er '.binding.results_bucket' "$AWS_TASK_B_REVIEW")"
readonly DEPLOYER_ROLE_ARN="$(jq -er '.deployer_role_arn.value' "$AWS_PLATFORM_OUTPUTS")"
readonly PUBLISHER_ROLE_ARN="$(jq -er '.receipt_publisher_role_arn.value' "$AWS_PLATFORM_OUTPUTS")"
readonly LOCAL_RECEIPT_KEY="runs/${DEPLOYMENT_ID}/control-input/execution-receipt.local.json"
readonly LOG_KEY="runs/${DEPLOYMENT_ID}/logs/bootstrap.log"
readonly MANIFEST_KEY="runs/${DEPLOYMENT_ID}/results/result-manifest.json"
readonly CONTROL_EVIDENCE_PREFIX="control/evidence/${DEPLOYMENT_ID}"
readonly FINAL_RECEIPT_KEY="control/receipts/${DEPLOYMENT_ID}/completion.v1.json"

source_assume_json="$(aws_dummy_aws sts assume-role --role-arn "$DEPLOYER_ROLE_ARN" \
  --role-session-name "receipt-review-${DEPLOYMENT_ID:0:30}" --duration-seconds 900)"
deployer_access_key="$(jq -er '.Credentials.AccessKeyId' <<<"$source_assume_json")"
deployer_secret_key="$(jq -er '.Credentials.SecretAccessKey' <<<"$source_assume_json")"
deployer_session_token="$(jq -er '.Credentials.SessionToken' <<<"$source_assume_json")"
publisher_assume_json="$(
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  AWS_ACCESS_KEY_ID="$deployer_access_key" AWS_SECRET_ACCESS_KEY="$deployer_secret_key" \
  AWS_SESSION_TOKEN="$deployer_session_token" AWS_REGION="$AWS_REGION" \
  AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER='' \
    command aws sts assume-role --role-arn "$PUBLISHER_ROLE_ARN" \
      --role-session-name "trusted-receipt-${DEPLOYMENT_ID:0:30}" --duration-seconds 900 \
      --no-cli-pager --output json
)"
unset source_assume_json deployer_access_key deployer_secret_key deployer_session_token
publisher_access_key="$(jq -er '.Credentials.AccessKeyId' <<<"$publisher_assume_json")"
publisher_secret_key="$(jq -er '.Credentials.SecretAccessKey' <<<"$publisher_assume_json")"
publisher_session_token="$(jq -er '.Credentials.SessionToken' <<<"$publisher_assume_json")"
unset publisher_assume_json

publisher_aws() {
  (
    unset AWS_PROFILE AWS_DEFAULT_PROFILE
    AWS_ACCESS_KEY_ID="$publisher_access_key" AWS_SECRET_ACCESS_KEY="$publisher_secret_key" \
    AWS_SESSION_TOKEN="$publisher_session_token" AWS_REGION="$AWS_REGION" \
    AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER='' \
      command aws --region "$AWS_REGION" --no-cli-pager "$@" --output json
  )
}

publisher_aws sts get-caller-identity >"${AWS_EVIDENCE_DIRECTORY}/publisher-caller.json"
[[ "$(jq -er '.Arn' "${AWS_EVIDENCE_DIRECTORY}/publisher-caller.json")" == \
  "arn:aws:sts::${AWS_ACCOUNT_ID}:assumed-role/${PUBLISHER_ROLE_ARN##*/}/"* ]] ||
  aws_dummy_fail 'trusted publisher assumption did not resolve to the accepted role'

download_exact() {
  local key="$1"
  local destination="$2"
  local metadata_name="$3"
  publisher_aws s3api head-object --bucket "$RESULTS_BUCKET" --key "$key" \
    >"${AWS_EVIDENCE_DIRECTORY}/${metadata_name}-head.json"
  local version_id
  version_id="$(jq -er '.VersionId' "${AWS_EVIDENCE_DIRECTORY}/${metadata_name}-head.json")"
  publisher_aws s3api get-object --bucket "$RESULTS_BUCKET" --key "$key" --version-id "$version_id" \
    "$destination" >"${AWS_EVIDENCE_DIRECTORY}/${metadata_name}-get.json"
}

download_exact "$LOCAL_RECEIPT_KEY" "${AWS_EVIDENCE_DIRECTORY}/execution-receipt.local.json" local-receipt
download_exact "$LOG_KEY" "${AWS_EVIDENCE_DIRECTORY}/bootstrap.log" bootstrap-log
download_exact "$MANIFEST_KEY" "${AWS_EVIDENCE_DIRECTORY}/result-manifest.json" result-manifest

unset publisher_access_key publisher_secret_key publisher_session_token

check-jsonschema --schemafile "${AWS_DUMMY_REPOSITORY_ROOT}/shared/contracts/local-execution-receipt.schema.json" \
  "${AWS_EVIDENCE_DIRECTORY}/execution-receipt.local.json" >/dev/null ||
  aws_dummy_fail 'local execution receipt violates the accepted schema'
"${AWS_DUMMY_REPOSITORY_ROOT}/scripts/validate-result-manifest.sh" \
  "${AWS_EVIDENCE_DIRECTORY}/result-manifest.json" >/dev/null ||
  aws_dummy_fail 'canonical result manifest is invalid'
[[ "$(wc -c <"${AWS_EVIDENCE_DIRECTORY}/bootstrap.log")" -le 1048576 ]] ||
  aws_dummy_fail 'bounded bootstrap log exceeds one MiB'

readonly LOCAL_RECEIPT="${AWS_EVIDENCE_DIRECTORY}/execution-receipt.local.json"
readonly RESULT_MANIFEST="${AWS_EVIDENCE_DIRECTORY}/result-manifest.json"
readonly LOG_FILE="${AWS_EVIDENCE_DIRECTORY}/bootstrap.log"
readonly RUNNER_ID="$(jq -er '.runner_id.value' "$AWS_RUNNER_OUTPUTS")"
readonly SCHEDULE_NAME="$(jq -er '.provider_deadline_control.value | split("/")[-1]' "$AWS_RUNNER_OUTPUTS")"
aws_dummy_aws ec2 describe-instances --instance-ids "$RUNNER_ID" >"${AWS_EVIDENCE_DIRECTORY}/instance.json"
aws_dummy_aws scheduler get-schedule --name "$SCHEDULE_NAME" >"${AWS_EVIDENCE_DIRECTORY}/schedule.json"

jq -e \
  --slurpfile request "$AWS_RUNNER_REQUEST" \
  --slurpfile outputs "$AWS_RUNNER_OUTPUTS" \
  --arg deployment "$DEPLOYMENT_ID" '
  $request[0] as $request
  | $outputs[0] as $outputs
  | .execution_terminal == true
    and .deployment_id == $deployment
    and .provider == "aws"
    and .oci_repository == $request.oci_repository
    and .oci_digest == $request.oci_digest
    and .run_spec_uri == $request.run_spec_uri
    and .run_spec_sha256 == $request.run_spec_sha256
    and .run_spec_object_version == $request.run_spec_object_version
    and .maximum_runtime_minutes == $request.maximum_runtime_minutes
    and .data_uri == $outputs.data_uri.value
    and .results_uri == $outputs.results_uri.value
' "$LOCAL_RECEIPT" >/dev/null ||
  aws_dummy_fail 'workload-authored local receipt differs from the sealed runner request or outputs'
[[ "$(jq -er '.run_spec_sha256' "$RESULT_MANIFEST")" == "$(jq -er '.run_spec_sha256' "$AWS_RUNNER_REQUEST")" ]] ||
  aws_dummy_fail 'result manifest differs from the sealed runner request'
jq -e '
  [.Reservations[0].Instances[0].State.Name] | all(. == "stopping" or . == "stopped" or . == "shutting-down" or . == "terminated")
' "${AWS_EVIDENCE_DIRECTORY}/instance.json" >/dev/null ||
  aws_dummy_fail 'runner is not terminal at this point-in-time observation'

readonly LOCAL_RECEIPT_SHA256="$(aws_dummy_file_sha256 "$LOCAL_RECEIPT")"
readonly RESULT_MANIFEST_SHA256="$(aws_dummy_file_sha256 "$RESULT_MANIFEST")"
readonly LOG_SHA256="$(aws_dummy_file_sha256 "$LOG_FILE")"
readonly REQUEST_SHA256="$(jq -er '.request_sha256.value' "$AWS_RUNNER_OUTPUTS")"
readonly PLATFORM_CONTRACT_SHA256="$(jq -er '.platform_contract_sha256.value' "$AWS_RUNNER_OUTPUTS")"
readonly BACKEND_KEY="$(jq -er '.backend_binding.value.key' "$AWS_RUNNER_OUTPUTS")"

jq -cn \
  --slurpfile instance "${AWS_EVIDENCE_DIRECTORY}/instance.json" \
  --slurpfile schedule "${AWS_EVIDENCE_DIRECTORY}/schedule.json" \
  --slurpfile local_receipt "$LOCAL_RECEIPT" \
  --slurpfile result_manifest "$RESULT_MANIFEST" \
  --arg collected_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg account_id "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" --arg deployment_id "$DEPLOYMENT_ID" \
  --arg runner_id "$RUNNER_ID" --arg local_receipt_sha256 "$LOCAL_RECEIPT_SHA256" \
  --arg result_manifest_sha256 "$RESULT_MANIFEST_SHA256" --arg log_sha256 "$LOG_SHA256" '
  {schema_version:"1.0.0", provider:"aws", collected_at_utc:$collected_at_utc,
    account_id:$account_id, region:$region, deployment_id:$deployment_id, runner_id:$runner_id,
    instance:{state:$instance[0].Reservations[0].Instances[0].State.Name,
      launch_time:$instance[0].Reservations[0].Instances[0].LaunchTime,
      tags:$instance[0].Reservations[0].Instances[0].Tags},
    deadline_schedule:{name:$schedule[0].Name, expression:$schedule[0].ScheduleExpression,
      state:$schedule[0].State, target_arn:$schedule[0].Target.Arn},
    immutable_inputs:{local_receipt_sha256:$local_receipt_sha256,
      result_manifest_sha256:$result_manifest_sha256, log_sha256:$log_sha256},
    terminal:{status:$local_receipt[0].status, container_exit_code:$local_receipt[0].container_exit_code,
      manifest_artifact_count:($result_manifest[0].artifacts | length)}}
' >"${AWS_EVIDENCE_DIRECTORY}/control-evidence.json"
readonly CONTROL_EVIDENCE_SHA256="$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/control-evidence.json")"
readonly CONTROL_EVIDENCE_URI="s3://${RESULTS_BUCKET}/${CONTROL_EVIDENCE_PREFIX}/${CONTROL_EVIDENCE_SHA256}.json"
readonly RECEIPT_URI="s3://${RESULTS_BUCKET}/${FINAL_RECEIPT_KEY}"

jq -n \
  --slurpfile local_receipt "$LOCAL_RECEIPT" \
  --slurpfile outputs "$AWS_RUNNER_OUTPUTS" \
  --arg account_scope "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" --arg backend_key "$BACKEND_KEY" \
  --arg request_sha256 "$REQUEST_SHA256" --arg platform_contract_sha256 "$PLATFORM_CONTRACT_SHA256" \
  --arg receipt_publisher_identity "$PUBLISHER_ROLE_ARN" --arg receipt_uri "$RECEIPT_URI" \
  --arg control_evidence_uri "$CONTROL_EVIDENCE_URI" --arg control_evidence_sha256 "$CONTROL_EVIDENCE_SHA256" \
  --arg local_receipt_sha256 "$LOCAL_RECEIPT_SHA256" --arg result_manifest_sha256 "$RESULT_MANIFEST_SHA256" \
  --arg log_sha256 "$LOG_SHA256" '
  $local_receipt[0] as $local
  | $outputs[0] as $outputs
  | {
      schema_version:"1.0.0", terminal:true, deployment_id:$local.deployment_id, provider:"aws",
      account_scope:$account_scope, region:$region, backend_key:$backend_key,
      request_sha256:$request_sha256, platform_contract_sha256:$platform_contract_sha256,
      runner_id:$outputs.runner_id.value, workload_identity:$outputs.workload_identity.value,
      receipt_publisher_identity:$receipt_publisher_identity, receipt_uri:$receipt_uri,
      publication_mode:"control_identity_conditional_create",
      control_evidence_uri:$control_evidence_uri, control_evidence_sha256:$control_evidence_sha256,
      local_execution_receipt_sha256:$local_receipt_sha256,
      oci_repository:$local.oci_repository, oci_digest:$local.oci_digest,
      run_spec_uri:$local.run_spec_uri, run_spec_sha256:$local.run_spec_sha256,
      run_spec_object_version:$local.run_spec_object_version,
      resource_profile:$outputs.resolved_profile.value.requested,
      resolved_machine_type:$outputs.resolved_profile.value.provider_sku,
      resolved_vcpu:$outputs.resolved_profile.value.minimum_vcpu,
      resolved_memory_mib:$outputs.resolved_profile.value.minimum_memory_mib,
      capacity_mode:"standard", maximum_runtime_minutes:$local.maximum_runtime_minutes,
      started_at:$local.started_at_utc, deadline:$outputs.deadline.value, finished_at:$local.finished_at_utc,
      status:$local.status, container_exit_code:$local.container_exit_code,
      results_uri:$local.results_uri, log_sha256:$log_sha256
    }
  | if $local.status == "succeeded" then . + {result_manifest_sha256:$result_manifest_sha256} else . end
' >"${AWS_EVIDENCE_DIRECTORY}/completion-receipt.json"
"${AWS_DUMMY_REPOSITORY_ROOT}/scripts/validate-completion-receipt.sh" \
  "${AWS_EVIDENCE_DIRECTORY}/completion-receipt.json" >/dev/null ||
  aws_dummy_fail 'prepared completion receipt violates the accepted contract'
readonly COMPLETION_RECEIPT_SHA256="$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/completion-receipt.json")"
jq -cn --arg completion_receipt_sha256 "$COMPLETION_RECEIPT_SHA256" '
  {schema_version:"1.0.0", provider:"aws", completion_receipt_sha256:$completion_receipt_sha256}
' >"${AWS_EVIDENCE_DIRECTORY}/receipt-bundle.json"
readonly RECEIPT_BUNDLE_SHA256="$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/receipt-bundle.json")"
aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
jq -cn --arg status reviewed_not_authorized --arg completion_receipt_sha256 "$COMPLETION_RECEIPT_SHA256" \
  --arg receipt_bundle_sha256 "$RECEIPT_BUNDLE_SHA256" \
  --arg authorization "RECEIPT-PUBLISH EXACT ARTIFACT sha256:${RECEIPT_BUNDLE_SHA256} FOR aws" '
  {status:$status, completion_receipt_sha256:$completion_receipt_sha256,
    receipt_bundle_sha256:$receipt_bundle_sha256, exact_authorization_sentence:$authorization}
'
