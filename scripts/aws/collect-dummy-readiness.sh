#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'collect-aws-dummy-readiness: ERROR: %s\n' "$1" >&2
  exit 2
}

if (($# != 5)); then
  printf 'usage: %s EVIDENCE_DIRECTORY TASK_B_REVIEW TASK_B_ACCEPTANCE PLATFORM_OUTPUTS DEPLOYMENT_ID\n' "$0" >&2
  exit 2
fi

readonly EVIDENCE_DIRECTORY="$1"
readonly TASK_B_REVIEW="$2"
readonly TASK_B_ACCEPTANCE="$3"
readonly PLATFORM_OUTPUTS="$4"
readonly DEPLOYMENT_ID="$5"
readonly REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

for command_name in aws jq sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: ${command_name}"
done

[[ "$EVIDENCE_DIRECTORY" == /* && "$EVIDENCE_DIRECTORY" != /tmp/* ]] ||
  fail 'evidence directory must be an absolute durable path outside /tmp'
case "$EVIDENCE_DIRECTORY/" in
  "$REPOSITORY_ROOT"/*) fail 'evidence directory must be outside the repository' ;;
esac
[[ "$DEPLOYMENT_ID" =~ ^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$ ]] ||
  fail 'deployment ID is invalid'
for input_path in "$TASK_B_REVIEW" "$TASK_B_ACCEPTANCE" "$PLATFORM_OUTPUTS"; do
  [[ "$input_path" == /* && -f "$input_path" && ! -L "$input_path" && -s "$input_path" ]] ||
    fail "required evidence is not a non-empty absolute regular file: ${input_path}"
done
[[ "$(jq -er '.status' "$TASK_B_REVIEW")" == 'SAVED_PLAN_READY_FOR_EXACT_APPLY_REVIEW' ]] ||
  fail 'Task B review receipt is not accepted input evidence'
[[ "$(jq -er '.status' "$TASK_B_ACCEPTANCE")" == 'TASK_B_ACCEPTED' ]] ||
  fail 'Task B acceptance receipt is not accepted input evidence'

if [[ -e "$EVIDENCE_DIRECTORY" ]]; then
  [[ -d "$EVIDENCE_DIRECTORY" && ! -L "$EVIDENCE_DIRECTORY" ]] ||
    fail 'evidence destination exists but is not a non-symlink directory'
  [[ -z "$(find "$EVIDENCE_DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    fail 'evidence destination must be empty'
else
  mkdir -p -- "$EVIDENCE_DIRECTORY"
fi
chmod 0700 -- "$EVIDENCE_DIRECTORY"
umask 077

readonly ACCOUNT_ID="$(jq -er '.binding.aws_account_id' "$TASK_B_REVIEW")"
readonly REGION="$(jq -er '.binding.aws_region' "$TASK_B_REVIEW")"
readonly AVAILABILITY_ZONE="$(jq -er '.binding.availability_zone' "$TASK_B_REVIEW")"
readonly PROJECT_NAME="$(jq -er '.binding.project_name' "$TASK_B_REVIEW")"
readonly RESOURCE_PREFIX="$(jq -er '.binding.resource_prefix' "$TASK_B_REVIEW")"
readonly STATE_BUCKET="$(jq -er '.binding.state_bucket' "$TASK_B_REVIEW")"
readonly PLATFORM_BACKEND_KEY="$(jq -er '.binding.platform_backend_key' "$TASK_B_REVIEW")"
readonly DATA_BUCKET="$(jq -er '.binding.data_bucket' "$TASK_B_REVIEW")"
readonly RESULTS_BUCKET="$(jq -er '.binding.results_bucket' "$TASK_B_REVIEW")"
readonly ECR_REPOSITORY="$(jq -er '.binding.ecr_repository' "$TASK_B_REVIEW")"
readonly ACCEPTED_STATE_VERSION="$(jq -er '.state.version_id' "$TASK_B_ACCEPTANCE")"
readonly ACCEPTED_PLATFORM_SHA256="$(jq -er '.platform_contract.canonical_sha256' "$TASK_B_ACCEPTANCE")"
readonly DEPLOYER_ROLE_NAME="${RESOURCE_PREFIX}-tofu-deployer"
readonly DEPLOYER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${DEPLOYER_ROLE_NAME}"
readonly PUBLISHER_ROLE_NAME="${RESOURCE_PREFIX}-receipt-publisher"
readonly PUBLISHER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PUBLISHER_ROLE_NAME}"
readonly PUBLISHER_POLICY_NAME="${RESOURCE_PREFIX}-conditional-receipt-create"
readonly INSTANCE_TYPE="${AWS_DUMMY_INSTANCE_TYPE:-t3.large}"
readonly QUOTA_CODE="L-1216C47A"
readonly AMI_PARAMETER="/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"

[[ "${AWS_ACCOUNT_ID:-}" == "$ACCOUNT_ID" ]] || fail 'AWS_ACCOUNT_ID does not match Task B evidence'
[[ "${AWS_REGION:-}" == "$REGION" ]] || fail 'AWS_REGION does not match Task B evidence'
[[ -n "${AWS_PROFILE:-}" ]] || fail 'AWS_PROFILE is required'
export AWS_PAGER=''

aws_read() {
  command aws --profile "$AWS_PROFILE" --region "$REGION" --no-cli-pager "$@" --output json
}

capture() {
  local name="$1"
  shift
  aws_read "$@" >"${EVIDENCE_DIRECTORY}/${name}.json"
}

capture source-caller sts get-caller-identity
capture region ec2 describe-regions --region-names "$REGION"
capture ec2-standard-quota service-quotas get-service-quota --service-code ec2 --quota-code "$QUOTA_CODE"
capture ami-parameter ssm get-parameter --name "$AMI_PARAMETER"
readonly AMI_ID="$(jq -er '.Parameter.Value' "${EVIDENCE_DIRECTORY}/ami-parameter.json")"
capture ami ec2 describe-images --image-ids "$AMI_ID"
capture instance-type ec2 describe-instance-types --instance-types "$INSTANCE_TYPE"
capture instance-offering ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=location,Values=${AVAILABILITY_ZONE}" "Name=instance-type,Values=${INSTANCE_TYPE}"

capture state-object s3api head-object --bucket "$STATE_BUCKET" --key "$PLATFORM_BACKEND_KEY"
capture state-versions s3api list-object-versions --bucket "$STATE_BUCKET" --prefix "$PLATFORM_BACKEND_KEY"
for bucket_kind in state data results; do
  case "$bucket_kind" in
    state) bucket_name="$STATE_BUCKET" ;;
    data) bucket_name="$DATA_BUCKET" ;;
    results) bucket_name="$RESULTS_BUCKET" ;;
  esac
  capture "${bucket_kind}-versioning" s3api get-bucket-versioning --bucket "$bucket_name"
  capture "${bucket_kind}-encryption" s3api get-bucket-encryption --bucket "$bucket_name"
  capture "${bucket_kind}-public-access" s3api get-public-access-block --bucket "$bucket_name"
  capture "${bucket_kind}-ownership" s3api get-bucket-ownership-controls --bucket "$bucket_name"
done

capture vpc ec2 describe-vpcs --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=tag:Root,Values=platform"
capture subnet ec2 describe-subnets --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=tag:Root,Values=platform"
capture security-group ec2 describe-security-groups --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=tag:Root,Values=platform"
capture ecr-repository ecr describe-repositories --repository-names "$ECR_REPOSITORY"
capture ecr-images ecr describe-images --repository-name "$ECR_REPOSITORY" --filter tagStatus=ANY

readonly INPUT_SHA256="${INPUT_SHA256:-}"
readonly RUN_SPEC_SHA256="${RUN_SPEC_SHA256:-}"
[[ "$INPUT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'INPUT_SHA256 is required and invalid'
[[ "$RUN_SPEC_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'RUN_SPEC_SHA256 is required and invalid'
capture input-prefix s3api list-objects-v2 --bucket "$DATA_BUCKET" \
  --prefix "fixtures/tool-complete-dummy/${INPUT_SHA256}.parquet"
capture run-spec-prefix s3api list-objects-v2 --bucket "$RESULTS_BUCKET" \
  --prefix "run-specs/${DEPLOYMENT_ID}/${RUN_SPEC_SHA256}.json"
capture deployment-prefix s3api list-objects-v2 --bucket "$RESULTS_BUCKET" \
  --prefix "runs/${DEPLOYMENT_ID}/"
capture receipt-prefix s3api list-objects-v2 --bucket "$RESULTS_BUCKET" \
  --prefix "control/receipts/${DEPLOYMENT_ID}/"
capture results-policy s3api get-bucket-policy --bucket "$RESULTS_BUCKET"

capture runner-instances ec2 describe-instances \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=tag:Root,Values=runner"
capture schedules scheduler list-schedules --name-prefix "${RESOURCE_PREFIX}-run-"
capture ssm-managed-instances ssm describe-instance-information
capture deployer-role iam get-role --role-name "$DEPLOYER_ROLE_NAME"
capture deployer-policy iam get-role-policy --role-name "$DEPLOYER_ROLE_NAME" \
  --policy-name "${RESOURCE_PREFIX}-disposable-runner-deployer"
capture publisher-role iam get-role --role-name "$PUBLISHER_ROLE_NAME"
capture publisher-policy iam get-role-policy --role-name "$PUBLISHER_ROLE_NAME" \
  --policy-name "$PUBLISHER_POLICY_NAME"
capture publisher-inline-policies iam list-role-policies --role-name "$PUBLISHER_ROLE_NAME"
capture publisher-attached-policies iam list-attached-role-policies --role-name "$PUBLISHER_ROLE_NAME"

assume_json="$(aws_read sts assume-role \
  --role-arn "$DEPLOYER_ROLE_ARN" \
  --role-session-name "dummy-readiness-${DEPLOYMENT_ID:0:32}" \
  --duration-seconds 900)"
(
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  AWS_ACCESS_KEY_ID="$(jq -er '.Credentials.AccessKeyId' <<<"$assume_json")" \
  AWS_SECRET_ACCESS_KEY="$(jq -er '.Credentials.SecretAccessKey' <<<"$assume_json")" \
  AWS_SESSION_TOKEN="$(jq -er '.Credentials.SessionToken' <<<"$assume_json")" \
  AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER='' \
    command aws sts get-caller-identity --no-cli-pager --output json
) >"${EVIDENCE_DIRECTORY}/deployer-assumed-caller.json"
unset assume_json

readonly SOURCE_CALLER_ARN="$(jq -er '.Arn' "${EVIDENCE_DIRECTORY}/source-caller.json")"
readonly ASSUMED_CALLER_ARN="$(jq -er '.Arn' "${EVIDENCE_DIRECTORY}/deployer-assumed-caller.json")"
readonly LIVE_STATE_VERSION="$(jq -er '.VersionId' "${EVIDENCE_DIRECTORY}/state-object.json")"
readonly LIVE_PLATFORM_SHA256="$(jq -cS '.platform_contract.value' "$PLATFORM_OUTPUTS" | sha256sum | cut -d' ' -f1)"
readonly QUOTA_VALUE="$(jq -er '.Quota.Value' "${EVIDENCE_DIRECTORY}/ec2-standard-quota.json")"
readonly REQUIRED_VCPU="$(jq -er '.InstanceTypes[0].VCpuInfo.DefaultVCpus' "${EVIDENCE_DIRECTORY}/instance-type.json")"
readonly PUBLISHER_POLICY="${EVIDENCE_DIRECTORY}/publisher-policy.json"
readonly CANONICAL_MANIFEST_ARN="arn:aws:s3:::${RESULTS_BUCKET}/runs/*/results/result-manifest.json"

source_identity_ok=false
[[ "$(jq -er '.Account' "${EVIDENCE_DIRECTORY}/source-caller.json")" == "$ACCOUNT_ID" ]] && source_identity_ok=true
deployer_trust_ok=false
jq -e --arg source "$SOURCE_CALLER_ARN" '
  .Role.AssumeRolePolicyDocument.Statement == [{
    Action:"sts:AssumeRole", Effect:"Allow", Principal:{AWS:$source},
    Sid:"ReviewedTemporaryPrincipalsOnly"
  }]
' "${EVIDENCE_DIRECTORY}/deployer-role.json" >/dev/null && deployer_trust_ok=true
deployer_assumption_ok=false
[[ "$ASSUMED_CALLER_ARN" == "arn:aws:sts::${ACCOUNT_ID}:assumed-role/${DEPLOYER_ROLE_NAME}/"* ]] && deployer_assumption_ok=true
quota_ok=false
jq -en --argjson quota "$QUOTA_VALUE" --argjson required "$REQUIRED_VCPU" '$quota >= $required' >/dev/null && quota_ok=true
ami_ok=false
jq -e --arg ami "$AMI_ID" '
  [.Images[] | select(.ImageId == $ami and .State == "available" and .Architecture == "x86_64")] | length == 1
' "${EVIDENCE_DIRECTORY}/ami.json" >/dev/null && ami_ok=true
offering_ok=false
jq -e --arg instance_type "$INSTANCE_TYPE" --arg zone "$AVAILABILITY_ZONE" '
  [.InstanceTypeOfferings[] | select(.InstanceType == $instance_type and .Location == $zone)] | length == 1
' "${EVIDENCE_DIRECTORY}/instance-offering.json" >/dev/null && offering_ok=true
state_lineage_ok=false
[[ "$LIVE_STATE_VERSION" == "$ACCEPTED_STATE_VERSION" && "$LIVE_PLATFORM_SHA256" == "$ACCEPTED_PLATFORM_SHA256" ]] && state_lineage_ok=true
platform_resources_ok=false
jq -e '.Repositories | length == 1 and .Repositories[0].imageTagMutability == "IMMUTABLE"' \
  "${EVIDENCE_DIRECTORY}/ecr-repository.json" >/dev/null &&
  jq -e '.Vpcs | length == 1' "${EVIDENCE_DIRECTORY}/vpc.json" >/dev/null &&
  jq -e '.Subnets | length == 1' "${EVIDENCE_DIRECTORY}/subnet.json" >/dev/null &&
  jq -e '.SecurityGroups | length == 1 and (.SecurityGroups[0].IpPermissions | length) == 0' \
    "${EVIDENCE_DIRECTORY}/security-group.json" >/dev/null && platform_resources_ok=true
runner_absent=false
jq -e '[.Reservations[].Instances[] | select(.State.Name != "terminated")] | length == 0' \
  "${EVIDENCE_DIRECTORY}/runner-instances.json" >/dev/null && runner_absent=true
schedules_absent=false
jq -e '.Schedules | length == 0' "${EVIDENCE_DIRECTORY}/schedules.json" >/dev/null && schedules_absent=true
target_prefixes_empty=false
jq -e '.KeyCount == 0' "${EVIDENCE_DIRECTORY}/input-prefix.json" >/dev/null &&
  jq -e '.KeyCount == 0' "${EVIDENCE_DIRECTORY}/run-spec-prefix.json" >/dev/null &&
  jq -e '.KeyCount == 0' "${EVIDENCE_DIRECTORY}/deployment-prefix.json" >/dev/null &&
  jq -e '.KeyCount == 0' "${EVIDENCE_DIRECTORY}/receipt-prefix.json" >/dev/null && target_prefixes_empty=true
publisher_trust_ok=false
jq -e --arg deployer "$DEPLOYER_ROLE_ARN" '
  .Role.AssumeRolePolicyDocument.Statement == [{
    Action:"sts:AssumeRole", Effect:"Allow", Principal:{AWS:$deployer},
    Sid:"ReviewedControlPrincipalsOnly"
  }]
' "${EVIDENCE_DIRECTORY}/publisher-role.json" >/dev/null && publisher_trust_ok=true
publisher_manifest_read=false
jq -e --arg resource "$CANONICAL_MANIFEST_ARN" '
  [.PolicyDocument.Statement[] | select(.Sid == "ReadBoundedRunnerEvidence") | .Resource[]]
  | index($resource) != null
' "$PUBLISHER_POLICY" >/dev/null && publisher_manifest_read=true
publisher_policy_closed=false
if jq -e --arg policy "$PUBLISHER_POLICY_NAME" '
    .PolicyNames == [$policy]
  ' "${EVIDENCE_DIRECTORY}/publisher-inline-policies.json" >/dev/null &&
  jq -e '.AttachedPolicies == []' "${EVIDENCE_DIRECTORY}/publisher-attached-policies.json" >/dev/null &&
  "${REPOSITORY_ROOT}/scripts/aws/validate-dummy-publisher-policy.sh" \
    "$PUBLISHER_POLICY" "$ACCOUNT_ID" "$REGION" "$RESULTS_BUCKET" "$RESOURCE_PREFIX" >/dev/null; then
  publisher_policy_closed=true
fi
results_bucket_policy_no_allow=false
jq -e '
  .Policy | fromjson
  | .Statement as $statements
  | ($statements | type == "array")
    and ($statements | length > 0)
    and all($statements[]; .Effect == "Deny")
' "${EVIDENCE_DIRECTORY}/results-policy.json" >/dev/null && results_bucket_policy_no_allow=true
publisher_arbitrary_results_read=true
[[ "$publisher_policy_closed" == true && "$results_bucket_policy_no_allow" == true ]] &&
  publisher_arbitrary_results_read=false

status=pass
for required_check in \
  "$source_identity_ok" "$deployer_trust_ok" "$deployer_assumption_ok" "$quota_ok" \
  "$ami_ok" "$offering_ok" "$state_lineage_ok" "$platform_resources_ok" \
  "$runner_absent" "$schedules_absent" "$target_prefixes_empty" "$publisher_trust_ok" \
  "$publisher_manifest_read" "$publisher_policy_closed" "$results_bucket_policy_no_allow"; do
  [[ "$required_check" == true ]] || status=blocked
done
[[ "$publisher_arbitrary_results_read" == false ]] || status=blocked

jq -cn \
  --arg status "$status" \
  --arg checked_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg account_id "$ACCOUNT_ID" \
  --arg region "$REGION" \
  --arg source_caller_arn "$SOURCE_CALLER_ARN" \
  --arg deployer_role_arn "$DEPLOYER_ROLE_ARN" \
  --arg assumed_caller_arn "$ASSUMED_CALLER_ARN" \
  --arg publisher_role_arn "$PUBLISHER_ROLE_ARN" \
  --arg deployment_id "$DEPLOYMENT_ID" \
  --arg instance_type "$INSTANCE_TYPE" \
  --arg ami_id "$AMI_ID" \
  --arg state_version "$LIVE_STATE_VERSION" \
  --arg platform_contract_sha256 "$LIVE_PLATFORM_SHA256" \
  --argjson quota_vcpu "$QUOTA_VALUE" \
  --argjson required_vcpu "$REQUIRED_VCPU" \
  --argjson source_identity "$source_identity_ok" \
  --argjson deployer_trust "$deployer_trust_ok" \
  --argjson deployer_assumption "$deployer_assumption_ok" \
  --argjson quota "$quota_ok" \
  --argjson ami "$ami_ok" \
  --argjson instance_offering "$offering_ok" \
  --argjson backend_lineage "$state_lineage_ok" \
  --argjson persistent_resources "$platform_resources_ok" \
  --argjson runner_absent "$runner_absent" \
  --argjson schedules_absent "$schedules_absent" \
  --argjson target_prefixes_empty "$target_prefixes_empty" \
  --argjson publisher_trust "$publisher_trust_ok" \
  --argjson publisher_manifest_read "$publisher_manifest_read" \
  --argjson publisher_policy_closed "$publisher_policy_closed" \
  --argjson results_bucket_policy_no_allow "$results_bucket_policy_no_allow" \
  --argjson publisher_arbitrary_results_read "$publisher_arbitrary_results_read" '
  {
    schema_version: "1.0.0",
    status: $status,
    checked_at_utc: $checked_at_utc,
    scope: {account_id: $account_id, region: $region, deployment_id: $deployment_id},
    identities: {
      source_caller_arn: $source_caller_arn,
      deployer_role_arn: $deployer_role_arn,
      assumed_caller_arn: $assumed_caller_arn,
      publisher_role_arn: $publisher_role_arn
    },
    capacity: {
      instance_type: $instance_type,
      ami_id: $ami_id,
      quota_vcpu: $quota_vcpu,
      required_vcpu: $required_vcpu
    },
    lineage: {
      platform_state_version: $state_version,
      platform_contract_sha256: $platform_contract_sha256
    },
    checks: {
      source_identity: $source_identity,
      deployer_trust: $deployer_trust,
      deployer_assumption: $deployer_assumption,
      quota: $quota,
      ami: $ami,
      instance_offering: $instance_offering,
      backend_lineage: $backend_lineage,
      persistent_resources: $persistent_resources,
      runner_absent: $runner_absent,
      schedules_absent: $schedules_absent,
      target_prefixes_empty: $target_prefixes_empty,
      publisher_trust: $publisher_trust,
      publisher_manifest_read: $publisher_manifest_read,
      publisher_policy_closed: $publisher_policy_closed,
      results_bucket_policy_no_allow: $results_bucket_policy_no_allow,
      publisher_arbitrary_results_read: $publisher_arbitrary_results_read
    },
    next_gate: (
      if $publisher_policy_closed and $results_bucket_policy_no_allow then
        "AWS dummy preflight may proceed; every mutation remains separately authorized"
      else
        "Prepare a newly reviewed exact platform policy plan before publication; do not apply without exact authorization"
      end
    )
  }
' >"${EVIDENCE_DIRECTORY}/readiness-summary.json"

(
  cd -- "$EVIDENCE_DIRECTORY"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' |
    sort |
    while IFS= read -r file_name; do
      sha256sum "$file_name"
    done >SHA256SUMS
)

jq -cS . "${EVIDENCE_DIRECTORY}/readiness-summary.json"
[[ "$status" == pass ]] || exit 4
