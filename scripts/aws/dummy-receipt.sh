#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIRECTORY}/dummy-adapter-lib.sh"

if (($# != 1)); then
  aws_dummy_fail 'usage: scripts/aws/dummy-receipt.sh receipt-publish|receipt-check'
fi
readonly OPERATION="$1"
[[ "$OPERATION" == receipt-publish || "$OPERATION" == receipt-check ]] ||
  aws_dummy_fail "unsupported receipt operation: ${OPERATION}"
for command_name in aws base64 jq xxd; do aws_dummy_require_command "$command_name"; done
aws_dummy_load_scope
aws_dummy_require_task_b_evidence
if [[ "$OPERATION" == receipt-publish ]]; then
  aws_dummy_verify_file_sha256 RECEIPT_BUNDLE RECEIPT_BUNDLE_SHA256
  aws_dummy_verify_exact_authorization \
    RECEIPT_PUBLISH_AUTHORIZATION receipt-publish "$RECEIPT_BUNDLE_SHA256"
fi
aws_dummy_prepare_fresh_evidence_directory

validate_terminal_receipt_bindings() {
  local receipt_path="$1"
  local sealed_request_sha256 publisher_role_arn results_bucket
  aws_dummy_require_file AWS_RUNNER_REQUEST
  aws_dummy_require_file AWS_RUNNER_OUTPUTS
  "${AWS_DUMMY_REPOSITORY_ROOT}/scripts/validate-runner-request.sh" "$AWS_RUNNER_REQUEST" >/dev/null ||
    aws_dummy_fail 'AWS_RUNNER_REQUEST violates the accepted contract'
  "${AWS_DUMMY_REPOSITORY_ROOT}/scripts/validate-completion-receipt.sh" "$receipt_path" >/dev/null ||
    aws_dummy_fail 'completion receipt violates the accepted contract'
  sealed_request_sha256="$("${AWS_DUMMY_REPOSITORY_ROOT}/scripts/hash-runner-request.sh" "$AWS_RUNNER_REQUEST")"
  publisher_role_arn="$(jq -er '.receipt_publisher_role_arn.value' "$AWS_PLATFORM_OUTPUTS")"
  results_bucket="$(jq -er '.binding.results_bucket' "$AWS_TASK_B_REVIEW")"
  jq -e \
    --slurpfile request "$AWS_RUNNER_REQUEST" \
    --slurpfile outputs "$AWS_RUNNER_OUTPUTS" \
    --arg account_id "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
    --arg request_sha256 "$sealed_request_sha256" \
    --arg publisher_role_arn "$publisher_role_arn" \
    --arg results_bucket "$results_bucket" '
    $request[0] as $request
    | $outputs[0] as $outputs
    | .terminal == true
      and .provider == "aws"
      and .deployment_id == $request.deployment_id
      and .deployment_id == $outputs.deployment_id.value
      and .account_scope == $account_id
      and .region == $region
      and .backend_key == $outputs.backend_binding.value.key
      and .request_sha256 == $request_sha256
      and $outputs.request_sha256.value == $request_sha256
      and .platform_contract_sha256 == $outputs.platform_contract_sha256.value
      and .runner_id == $outputs.runner_id.value
      and .workload_identity == $outputs.workload_identity.value
      and .receipt_publisher_identity == $publisher_role_arn
      and .receipt_uri == $outputs.receipt_uri.value
      and .receipt_uri == ("s3://" + $results_bucket + "/control/receipts/" + $request.deployment_id + "/completion.v1.json")
      and .publication_mode == "control_identity_conditional_create"
      and .oci_repository == $request.oci_repository
      and .oci_digest == $request.oci_digest
      and .run_spec_uri == $request.run_spec_uri
      and .run_spec_sha256 == $request.run_spec_sha256
      and .run_spec_object_version == $request.run_spec_object_version
      and .resource_profile == $request.resource_profile
      and .resource_profile == $outputs.resolved_profile.value.requested
      and .resolved_machine_type == $outputs.resolved_profile.value.provider_sku
      and .resolved_vcpu == $outputs.resolved_profile.value.minimum_vcpu
      and .resolved_memory_mib == $outputs.resolved_profile.value.minimum_memory_mib
      and .capacity_mode == $request.capacity_mode
      and .maximum_runtime_minutes == $request.maximum_runtime_minutes
      and .deadline == $outputs.deadline.value
      and .results_uri == $outputs.results_uri.value
  ' "$receipt_path" >/dev/null ||
    aws_dummy_fail 'completion receipt is not a terminal result bound to the sealed request and runner outputs'
}

if [[ "$OPERATION" == receipt-check ]]; then
  aws_dummy_require_file FINAL_RECEIPT
  aws_dummy_require_file AWS_RECEIPT_PUBLICATION_RECORD
  aws_dummy_require_file AWS_RECEIPT_PUBLICATION_API_EVIDENCE
  validate_terminal_receipt_bindings "$FINAL_RECEIPT"
  deployment_id="$(jq -er '.deployment_id' "$FINAL_RECEIPT")"
  receipt_sha="$(aws_dummy_file_sha256 "$FINAL_RECEIPT")"
  receipt_checksum="$(printf '%s' "$receipt_sha" | xxd -r -p | base64 -w0)"
  receipt_bytes="$(wc -c <"$FINAL_RECEIPT")"
  terminal_status="$(jq -er '.status' "$FINAL_RECEIPT")"
  terminal_acceptance=false
  jq -e '.status == "succeeded" and .container_exit_code == 0 and has("result_manifest_sha256")' \
    "$FINAL_RECEIPT" >/dev/null && terminal_acceptance=true
  receipt_bucket="$(jq -er '.receipt_uri | sub("^s3://"; "") | split("/")[0]' "$FINAL_RECEIPT")"
  receipt_key="$(jq -er '.receipt_uri | sub("^s3://[^/]+/"; "")' "$FINAL_RECEIPT")"
  receipt_version="$(jq -er '.receipt_object_version' "$AWS_RECEIPT_PUBLICATION_RECORD")"
  publisher_role_arn="$(jq -er '.receipt_publisher_role_arn.value' "$AWS_PLATFORM_OUTPUTS")"
  provider_api_sha="$(aws_dummy_file_sha256 "$AWS_RECEIPT_PUBLICATION_API_EVIDENCE")"
  jq -e --arg deployment_id "$deployment_id" --arg publisher_role_arn "$publisher_role_arn" \
    --arg receipt_sha "$receipt_sha" --arg receipt_uri "s3://${receipt_bucket}/${receipt_key}" \
    --arg receipt_version "$receipt_version" --arg provider_api_sha "$provider_api_sha" '
    keys == ["deployment_id", "provider", "provider_api_evidence_sha256", "published_at_utc",
      "publisher_identity", "receipt_object_version", "receipt_sha256", "receipt_uri", "schema_version"]
    and .schema_version == "1.0.0"
    and .provider == "aws"
    and .deployment_id == $deployment_id
    and .publisher_identity == $publisher_role_arn
    and .receipt_sha256 == $receipt_sha
    and .receipt_uri == $receipt_uri
    and .receipt_object_version == $receipt_version
    and .provider_api_evidence_sha256 == $provider_api_sha
  ' "$AWS_RECEIPT_PUBLICATION_RECORD" >/dev/null ||
    aws_dummy_fail 'publication record does not exactly bind the receipt and provider API evidence'
  jq -e --arg account_id "$AWS_ACCOUNT_ID" --arg publisher_role_arn "$publisher_role_arn" \
    --arg receipt_sha "$receipt_sha" --arg receipt_checksum "$receipt_checksum" \
    --arg receipt_version "$receipt_version" --argjson receipt_bytes "$receipt_bytes" '
    (.publisher_caller | keys == ["Account", "Arn", "UserId"])
    and .publisher_caller.Account == $account_id
    and (.publisher_caller.Arn | startswith("arn:aws:sts::" + $account_id + ":assumed-role/" + ($publisher_role_arn | split("/")[-1]) + "/"))
    and (.control_put.VersionId | type == "string" and length > 0)
    and .receipt_put.VersionId == $receipt_version
    and .receipt_head.VersionId == $receipt_version
    and .receipt_head.ChecksumSHA256 == $receipt_checksum
    and .receipt_head.ContentLength == $receipt_bytes
    and .receipt_head.Metadata == {"publisher-role":$publisher_role_arn, sha256:$receipt_sha}
  ' "$AWS_RECEIPT_PUBLICATION_API_EVIDENCE" >/dev/null ||
    aws_dummy_fail 'provider API evidence does not authenticate the expected publisher and receipt version'
  aws_dummy_aws s3api head-object --bucket "$receipt_bucket" --key "$receipt_key" --version-id "$receipt_version" \
    --checksum-mode ENABLED \
    >"${AWS_EVIDENCE_DIRECTORY}/receipt-head.json"
  aws_dummy_aws s3api get-object --bucket "$receipt_bucket" --key "$receipt_key" --version-id "$receipt_version" \
    "${AWS_EVIDENCE_DIRECTORY}/completion-receipt.json" >"${AWS_EVIDENCE_DIRECTORY}/receipt-get.json"
  jq -e --arg publisher_role_arn "$publisher_role_arn" --arg receipt_sha "$receipt_sha" \
    --arg receipt_checksum "$receipt_checksum" --arg receipt_version "$receipt_version" \
    --argjson receipt_bytes "$receipt_bytes" '
    .VersionId == $receipt_version
    and .ChecksumSHA256 == $receipt_checksum
    and .ContentLength == $receipt_bytes
    and .Metadata == {"publisher-role":$publisher_role_arn, sha256:$receipt_sha}
  ' "${AWS_EVIDENCE_DIRECTORY}/receipt-head.json" >/dev/null ||
    aws_dummy_fail 'live provider metadata does not authenticate the exact receipt publication'
  [[ "$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/completion-receipt.json")" == "$receipt_sha" ]] ||
    aws_dummy_fail 'live provider object differs from FINAL_RECEIPT'
  cp -- "$AWS_RECEIPT_PUBLICATION_RECORD" "${AWS_EVIDENCE_DIRECTORY}/receipt-publication.json"
  cp -- "$AWS_RECEIPT_PUBLICATION_API_EVIDENCE" "${AWS_EVIDENCE_DIRECTORY}/receipt-publication-provider-api.json"
  aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
  jq -cn --arg status verified --arg deployment_id "$deployment_id" --arg receipt_sha256 "$receipt_sha" \
    --arg receipt_object_version "$receipt_version" --arg terminal_status "$terminal_status" \
    --argjson terminal_acceptance "$terminal_acceptance" '
    {schema_version:"1.0.0", status:$status, provider:"aws", deployment_id:$deployment_id,
      terminal_status:$terminal_status, terminal_acceptance:$terminal_acceptance,
      receipt_sha256:$receipt_sha256, receipt_object_version:$receipt_object_version}
  '
  exit 0
fi

aws_dummy_require_deployment
aws_dummy_require_file RECEIPT_BUNDLE
aws_dummy_require_file AWS_COMPLETION_RECEIPT
aws_dummy_require_file AWS_CONTROL_EVIDENCE
readonly COMPLETION_RECEIPT_SHA256="$(aws_dummy_file_sha256 "$AWS_COMPLETION_RECEIPT")"
readonly CONTROL_EVIDENCE_SHA256="$(aws_dummy_file_sha256 "$AWS_CONTROL_EVIDENCE")"
jq -e --arg receipt_sha "$COMPLETION_RECEIPT_SHA256" '
  keys == ["completion_receipt_sha256", "provider", "schema_version"]
  and .schema_version == "1.0.0" and .provider == "aws" and .completion_receipt_sha256 == $receipt_sha
' "$RECEIPT_BUNDLE" >/dev/null || aws_dummy_fail 'RECEIPT_BUNDLE does not bind AWS_COMPLETION_RECEIPT'
validate_terminal_receipt_bindings "$AWS_COMPLETION_RECEIPT"
jq -e --arg deployment "$DEPLOYMENT_ID" --arg evidence_sha "$CONTROL_EVIDENCE_SHA256" '
  .deployment_id == $deployment and .provider == "aws"
  and .control_evidence_sha256 == $evidence_sha
' "$AWS_COMPLETION_RECEIPT" >/dev/null || aws_dummy_fail 'completion receipt does not bind the control evidence or deployment'

readonly DEPLOYER_ROLE_ARN="$(jq -er '.deployer_role_arn.value' "$AWS_PLATFORM_OUTPUTS")"
readonly PUBLISHER_ROLE_ARN="$(jq -er '.receipt_publisher_role_arn.value' "$AWS_PLATFORM_OUTPUTS")"
readonly RESULTS_BUCKET="$(jq -er '.binding.results_bucket' "$AWS_TASK_B_REVIEW")"
readonly CONTROL_KEY="control/evidence/${DEPLOYMENT_ID}/${CONTROL_EVIDENCE_SHA256}.json"
readonly RECEIPT_KEY="control/receipts/${DEPLOYMENT_ID}/completion.v1.json"

deployer_assume="$(aws_dummy_aws sts assume-role --role-arn "$DEPLOYER_ROLE_ARN" \
  --role-session-name "receipt-publish-${DEPLOYMENT_ID:0:29}" --duration-seconds 900)"
deployer_access="$(jq -er '.Credentials.AccessKeyId' <<<"$deployer_assume")"
deployer_secret="$(jq -er '.Credentials.SecretAccessKey' <<<"$deployer_assume")"
deployer_token="$(jq -er '.Credentials.SessionToken' <<<"$deployer_assume")"
publisher_assume="$(
  AWS_ACCESS_KEY_ID="$deployer_access" AWS_SECRET_ACCESS_KEY="$deployer_secret" AWS_SESSION_TOKEN="$deployer_token" \
  AWS_PROFILE='' AWS_DEFAULT_PROFILE='' AWS_REGION="$AWS_REGION" AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER='' \
    command aws sts assume-role --role-arn "$PUBLISHER_ROLE_ARN" \
      --role-session-name "trusted-publish-${DEPLOYMENT_ID:0:30}" --duration-seconds 900 --no-cli-pager --output json
)"
unset deployer_assume deployer_access deployer_secret deployer_token
publisher_access="$(jq -er '.Credentials.AccessKeyId' <<<"$publisher_assume")"
publisher_secret="$(jq -er '.Credentials.SecretAccessKey' <<<"$publisher_assume")"
publisher_token="$(jq -er '.Credentials.SessionToken' <<<"$publisher_assume")"
unset publisher_assume
publisher_aws() {
  AWS_ACCESS_KEY_ID="$publisher_access" AWS_SECRET_ACCESS_KEY="$publisher_secret" AWS_SESSION_TOKEN="$publisher_token" \
  AWS_PROFILE='' AWS_DEFAULT_PROFILE='' AWS_REGION="$AWS_REGION" AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER='' \
    command aws --region "$AWS_REGION" --no-cli-pager "$@" --output json
}

publisher_aws sts get-caller-identity >"${AWS_EVIDENCE_DIRECTORY}/publisher-caller.json"
[[ "$(jq -er '.Arn' "${AWS_EVIDENCE_DIRECTORY}/publisher-caller.json")" == \
  "arn:aws:sts::${AWS_ACCOUNT_ID}:assumed-role/${PUBLISHER_ROLE_ARN##*/}/"* ]] ||
  aws_dummy_fail 'receipt publisher assumption resolved to the wrong identity'
control_checksum="$(printf '%s' "$CONTROL_EVIDENCE_SHA256" | xxd -r -p | base64 -w0)"
receipt_checksum="$(printf '%s' "$COMPLETION_RECEIPT_SHA256" | xxd -r -p | base64 -w0)"
publisher_aws s3api put-object --bucket "$RESULTS_BUCKET" --key "$CONTROL_KEY" --body "$AWS_CONTROL_EVIDENCE" \
  --if-none-match '*' --checksum-algorithm SHA256 --checksum-sha256 "$control_checksum" \
  --metadata "publisher-role=${PUBLISHER_ROLE_ARN},sha256=${CONTROL_EVIDENCE_SHA256}" \
  >"${AWS_EVIDENCE_DIRECTORY}/control-put.json"
set +e
publisher_aws s3api put-object --bucket "$RESULTS_BUCKET" --key "$RECEIPT_KEY" --body "$AWS_COMPLETION_RECEIPT" \
  --if-none-match '*' --checksum-algorithm SHA256 --checksum-sha256 "$receipt_checksum" \
  --metadata "publisher-role=${PUBLISHER_ROLE_ARN},sha256=${COMPLETION_RECEIPT_SHA256}" \
  >"${AWS_EVIDENCE_DIRECTORY}/receipt-put.json" 2>"${AWS_EVIDENCE_DIRECTORY}/receipt-put.stderr"
receipt_put_exit=$?
set -e
unset publisher_access publisher_secret publisher_token
[[ "$receipt_put_exit" -eq 0 ]] ||
  aws_dummy_fail 'final receipt conditional publication failed after control evidence publication; preserve evidence and do not retry'

receipt_version="$(jq -er '.VersionId' "${AWS_EVIDENCE_DIRECTORY}/receipt-put.json")"
aws_dummy_aws s3api head-object --bucket "$RESULTS_BUCKET" --key "$RECEIPT_KEY" --version-id "$receipt_version" \
  --checksum-mode ENABLED \
  >"${AWS_EVIDENCE_DIRECTORY}/receipt-head.json"
aws_dummy_aws s3api head-object --bucket "$RESULTS_BUCKET" --key "$CONTROL_KEY" \
  --version-id "$(jq -er '.VersionId' "${AWS_EVIDENCE_DIRECTORY}/control-put.json")" \
  >"${AWS_EVIDENCE_DIRECTORY}/control-head.json"
jq -n --slurpfile caller "${AWS_EVIDENCE_DIRECTORY}/publisher-caller.json" \
  --slurpfile control_put "${AWS_EVIDENCE_DIRECTORY}/control-put.json" \
  --slurpfile receipt_put "${AWS_EVIDENCE_DIRECTORY}/receipt-put.json" \
  --slurpfile receipt_head "${AWS_EVIDENCE_DIRECTORY}/receipt-head.json" \
  '{publisher_caller:$caller[0], control_put:$control_put[0], receipt_put:$receipt_put[0], receipt_head:$receipt_head[0]}' \
  >"${AWS_EVIDENCE_DIRECTORY}/receipt-publication-provider-api.json"
api_sha="$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/receipt-publication-provider-api.json")"
jq -cn --arg published_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg deployment_id "$DEPLOYMENT_ID" \
  --arg publisher_identity "$PUBLISHER_ROLE_ARN" --arg receipt_object_version "$receipt_version" \
  --arg receipt_sha256 "$COMPLETION_RECEIPT_SHA256" --arg receipt_uri "s3://${RESULTS_BUCKET}/${RECEIPT_KEY}" \
  --arg provider_api_evidence_sha256 "$api_sha" '
  {schema_version:"1.0.0", provider:"aws", deployment_id:$deployment_id,
    published_at_utc:$published_at_utc, publisher_identity:$publisher_identity,
    receipt_object_version:$receipt_object_version, receipt_sha256:$receipt_sha256,
    receipt_uri:$receipt_uri, provider_api_evidence_sha256:$provider_api_evidence_sha256}
' >"${AWS_EVIDENCE_DIRECTORY}/receipt-publication.json"
cp -- "$AWS_COMPLETION_RECEIPT" "${AWS_EVIDENCE_DIRECTORY}/completion-receipt.json"
cp -- "$AWS_CONTROL_EVIDENCE" "${AWS_EVIDENCE_DIRECTORY}/control-evidence.json"
cp -- "$RECEIPT_BUNDLE" "${AWS_EVIDENCE_DIRECTORY}/receipt-bundle.json"
cp -- "$RECEIPT_PUBLISH_AUTHORIZATION" "${AWS_EVIDENCE_DIRECTORY}/receipt-publish-authorization.json"
aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
jq -cS . "${AWS_EVIDENCE_DIRECTORY}/receipt-publication.json"
