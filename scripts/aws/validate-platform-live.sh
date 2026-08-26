#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'validate-aws-platform-live: %s\n' "$1" >&2
  exit 1
}

if (($# != 3)); then
  printf 'usage: %s TASK_B_PLAN_REVIEW_RECEIPT_JSON PLATFORM_OUTPUTS_JSON AWS_PROFILE\n' "$0" >&2
  exit 2
fi

readonly REVIEW_RECEIPT="$1"
readonly PLATFORM_OUTPUTS="$2"
readonly PROFILE="$3"

for command_name in aws jq sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: ${command_name}"
done

[[ -f "$REVIEW_RECEIPT" ]] || fail "review receipt does not exist: ${REVIEW_RECEIPT}"
[[ -f "$PLATFORM_OUTPUTS" ]] || fail "platform outputs do not exist: ${PLATFORM_OUTPUTS}"
jq -e '.status == "SAVED_PLAN_READY_FOR_EXACT_APPLY_REVIEW"' "$REVIEW_RECEIPT" >/dev/null ||
  fail 'review receipt is not the accepted Task B saved-plan review schema/status'
jq -e . "$PLATFORM_OUTPUTS" >/dev/null || fail 'platform outputs JSON is invalid'

readonly ACCOUNT_ID="$(jq -er '.binding.aws_account_id' "$REVIEW_RECEIPT")"
readonly REGION="$(jq -er '.binding.aws_region' "$REVIEW_RECEIPT")"
readonly AVAILABILITY_ZONE="$(jq -er '.binding.availability_zone' "$REVIEW_RECEIPT")"
readonly PROJECT_NAME="$(jq -er '.binding.project_name' "$REVIEW_RECEIPT")"
readonly RESOURCE_PREFIX="$(jq -er '.binding.resource_prefix' "$REVIEW_RECEIPT")"
readonly STATE_BUCKET="$(jq -er '.binding.state_bucket' "$REVIEW_RECEIPT")"
readonly PLATFORM_BACKEND_KEY="$(jq -er '.binding.platform_backend_key' "$REVIEW_RECEIPT")"
readonly DATA_BUCKET="$(jq -er '.binding.data_bucket' "$REVIEW_RECEIPT")"
readonly RESULTS_BUCKET="$(jq -er '.binding.results_bucket' "$REVIEW_RECEIPT")"
readonly ECR_REPOSITORY="$(jq -er '.binding.ecr_repository' "$REVIEW_RECEIPT")"
readonly VPC_CIDR="$(jq -er '.binding.vpc_cidr' "$REVIEW_RECEIPT")"
readonly SUBNET_CIDR="$(jq -er '.binding.runner_subnet_cidr' "$REVIEW_RECEIPT")"
readonly EXPECTED_ENVIRONMENT="$(jq -er '.binding.tags.Environment' "$REVIEW_RECEIPT")"
readonly EXPECTED_OWNER="$(jq -er '.binding.tags.Owner' "$REVIEW_RECEIPT")"
readonly DEPLOYER_ROLE_NAME="${RESOURCE_PREFIX}-tofu-deployer"
readonly PUBLISHER_ROLE_NAME="${RESOURCE_PREFIX}-receipt-publisher"
readonly RUNTIME_BOUNDARY_NAME="${RESOURCE_PREFIX}-runtime-boundary"
readonly SCHEDULER_BOUNDARY_NAME="${RESOURCE_PREFIX}-scheduler-boundary"
readonly DEPLOYER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${DEPLOYER_ROLE_NAME}"
readonly PUBLISHER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PUBLISHER_ROLE_NAME}"
readonly RUNTIME_BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${RUNTIME_BOUNDARY_NAME}"
readonly SCHEDULER_BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${SCHEDULER_BOUNDARY_NAME}"
readonly STATE_BUCKET_ARN="arn:aws:s3:::${STATE_BUCKET}"
readonly DATA_BUCKET_ARN="arn:aws:s3:::${DATA_BUCKET}"
readonly RESULTS_BUCKET_ARN="arn:aws:s3:::${RESULTS_BUCKET}"
readonly ECR_REPOSITORY_ARN="arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPOSITORY}"

export AWS_PAGER=""

aws_read() {
  command aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@" --output json
}

assert_expected_tags() {
  local tags_json="$1"
  local label="$2"
  jq -e \
    --arg project "$PROJECT_NAME" \
    --arg environment "$EXPECTED_ENVIRONMENT" \
    --arg owner "$EXPECTED_OWNER" '
      def tagmap:
        if type == "object" then .
        else map({key:(.Key // .key), value:(.Value // .value)}) | from_entries
        end;
      tagmap as $tags |
      $tags.Project == $project and
      $tags.Root == "platform" and
      $tags.ManagedBy == "opentofu" and
      $tags.Environment == $environment and
      $tags.Owner == $owner
    ' <<<"$tags_json" >/dev/null || fail "${label} tags do not match the reviewed binding"
}

identity_json="$(aws_read sts get-caller-identity)"
jq -e --arg account "$ACCOUNT_ID" '.Account == $account' <<<"$identity_json" >/dev/null ||
  fail 'AWS caller account does not match the reviewed binding'

contract_json="$(jq -ec '.platform_contract.value' "$PLATFORM_OUTPUTS")"
contract_canonical="$(jq -cS . <<<"$contract_json")"
contract_sha256="$(printf '%s' "$contract_canonical" | sha256sum | awk '{print $1}')"
jq -e --arg sha256 "$contract_sha256" '.platform_contract_sha256.value == $sha256' "$PLATFORM_OUTPUTS" >/dev/null ||
  fail 'platform contract output hash does not match the independently canonicalized output'

jq -e \
  --arg account "$ACCOUNT_ID" \
  --arg region "$REGION" \
  --arg state_name "$STATE_BUCKET" \
  --arg state_arn "$STATE_BUCKET_ARN" \
  --arg data_name "$DATA_BUCKET" \
  --arg data_arn "$DATA_BUCKET_ARN" \
  --arg results_name "$RESULTS_BUCKET" \
  --arg results_arn "$RESULTS_BUCKET_ARN" \
  --arg ecr_arn "$ECR_REPOSITORY_ARN" \
  --arg runtime_boundary "$RUNTIME_BOUNDARY_ARN" \
  --arg scheduler_boundary "$SCHEDULER_BOUNDARY_ARN" \
  --arg publisher "$PUBLISHER_ROLE_ARN" '
    .schema_version == "1.0.0" and
    .provider == "aws" and
    .aws_account_id == $account and
    .aws_region == $region and
    .state_bucket_name == $state_name and
    .state_bucket_arn == $state_arn and
    .data_bucket_name == $data_name and
    .data_bucket_arn == $data_arn and
    .results_bucket_name == $results_name and
    .results_bucket_arn == $results_arn and
    .ecr_repository_arn == $ecr_arn and
    .runtime_permissions_boundary_arn == $runtime_boundary and
    .scheduler_permissions_boundary_arn == $scheduler_boundary and
    .receipt_publisher_role_arn == $publisher and
    (.runner_subnet_id | test("^subnet-[0-9a-f]{8,17}$")) and
    (.runner_security_group_id | test("^sg-[0-9a-f]{8,17}$"))
  ' <<<"$contract_json" >/dev/null || fail 'platform contract output violates the reviewed binding'

jq -e \
  --arg deployer "$DEPLOYER_ROLE_ARN" \
  --arg publisher "$PUBLISHER_ROLE_ARN" \
  --arg runtime "$RUNTIME_BOUNDARY_ARN" \
  --arg scheduler "$SCHEDULER_BOUNDARY_ARN" '
    .deployer_role_arn.value == $deployer and
    .receipt_publisher_role_arn.value == $publisher and
    .runtime_permissions_boundary_arn.value == $runtime and
    .scheduler_permissions_boundary_arn.value == $scheduler
  ' "$PLATFORM_OUTPUTS" >/dev/null || fail 'platform IAM outputs violate the reviewed binding'

validate_bucket() {
  local bucket_name="$1"
  local bucket_kind="$2"
  local location_json public_json versioning_json encryption_json ownership_json lifecycle_json tags_json policy_json objects_json

  location_json="$(aws_read s3api get-bucket-location --bucket "$bucket_name")"
  if [[ "$REGION" == "us-east-1" ]]; then
    jq -e '.LocationConstraint == null' <<<"$location_json" >/dev/null || fail "${bucket_kind} bucket is not in us-east-1"
  else
    jq -e --arg region "$REGION" '.LocationConstraint == $region' <<<"$location_json" >/dev/null || fail "${bucket_kind} bucket region is wrong"
  fi

  public_json="$(aws_read s3api get-public-access-block --bucket "$bucket_name")"
  jq -e '
    .PublicAccessBlockConfiguration |
    .BlockPublicAcls == true and
    .BlockPublicPolicy == true and
    .IgnorePublicAcls == true and
    .RestrictPublicBuckets == true
  ' <<<"$public_json" >/dev/null || fail "${bucket_kind} bucket public-access block is incomplete"

  versioning_json="$(aws_read s3api get-bucket-versioning --bucket "$bucket_name")"
  jq -e '.Status == "Enabled"' <<<"$versioning_json" >/dev/null || fail "${bucket_kind} bucket versioning is not enabled"

  encryption_json="$(aws_read s3api get-bucket-encryption --bucket "$bucket_name")"
  jq -e '
    (.ServerSideEncryptionConfiguration.Rules | length) == 1 and
    .ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm == "AES256"
  ' <<<"$encryption_json" >/dev/null || fail "${bucket_kind} bucket encryption is not AES256"

  ownership_json="$(aws_read s3api get-bucket-ownership-controls --bucket "$bucket_name")"
  jq -e '.OwnershipControls.Rules == [{ObjectOwnership:"BucketOwnerEnforced"}]' <<<"$ownership_json" >/dev/null ||
    fail "${bucket_kind} bucket ownership is not BucketOwnerEnforced"

  lifecycle_json="$(aws_read s3api get-bucket-lifecycle-configuration --bucket "$bucket_name")"
  jq -e '
    [.Rules[] | select(
      .ID == "abort-incomplete-multipart-uploads" and
      .Status == "Enabled" and
      .AbortIncompleteMultipartUpload.DaysAfterInitiation == 7
    )] | length == 1
  ' <<<"$lifecycle_json" >/dev/null || fail "${bucket_kind} bucket multipart lifecycle rule is wrong"

  tags_json="$(aws_read s3api get-bucket-tagging --bucket "$bucket_name")"
  assert_expected_tags "$(jq -c '.TagSet' <<<"$tags_json")" "${bucket_kind} bucket"

  policy_json="$(aws_read s3api get-bucket-policy --bucket "$bucket_name" | jq -er '.Policy | fromjson')"
  if [[ "$bucket_kind" == "data" ]]; then
    jq -e --arg bucket_arn "arn:aws:s3:::${bucket_name}" '
      def arr: if type == "array" then . else [.] end;
      (.Statement | length) == 1 and
      .Statement[0].Sid == "DenyInsecureTransport" and
      .Statement[0].Effect == "Deny" and
      (.Statement[0].Action | arr) == ["s3:*"] and
      (.Statement[0].Resource | arr | sort) == ([$bucket_arn, $bucket_arn + "/*"] | sort) and
      .Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    ' <<<"$policy_json" >/dev/null || fail 'data bucket policy violates the TLS-only contract'
  else
    jq -e '
      ([.Statement[].Sid] | sort) == ([
        "DenyControlDeletion",
        "DenyControlOverwrite",
        "DenyControlWritesFromOtherPrincipals",
        "DenyControlWritesWithoutConditionalCreate",
        "DenyInsecureTransport",
        "DenyLocalReceiptHandoffOverwrite",
        "DenyLocalReceiptHandoffWithoutConditionalCreate"
      ] | sort) and
      all(.Statement[]; .Effect == "Deny")
    ' <<<"$policy_json" >/dev/null || fail 'results bucket policy does not preserve the closed denial set'
  fi

  objects_json="$(aws_read s3api list-object-versions --bucket "$bucket_name")"
  jq -e '((.Versions // []) | length) == 0 and ((.DeleteMarkers // []) | length) == 0' <<<"$objects_json" >/dev/null ||
    fail "${bucket_kind} bucket is not empty"
}

validate_bucket "$DATA_BUCKET" data
validate_bucket "$RESULTS_BUCKET" results

state_versions_json="$(aws_read s3api list-object-versions --bucket "$STATE_BUCKET" --prefix "$PLATFORM_BACKEND_KEY")"
jq -e --arg state_key "$PLATFORM_BACKEND_KEY" --arg lock_key "${PLATFORM_BACKEND_KEY}.tflock" '
  ([.Versions[]? | select(.Key == $state_key)] | length) >= 1 and
  ([.Versions[]? | select(.Key == $lock_key and .IsLatest == true)] | length) == 0
' <<<"$state_versions_json" >/dev/null || fail 'platform state is absent or its native lock is still current'

ecr_json="$(aws_read ecr describe-repositories --repository-names "$ECR_REPOSITORY")"
jq -e \
  --arg name "$ECR_REPOSITORY" \
  --arg arn "$ECR_REPOSITORY_ARN" '
    (.repositories | length) == 1 and
    .repositories[0].repositoryName == $name and
    .repositories[0].repositoryArn == $arn and
    .repositories[0].imageTagMutability == "IMMUTABLE" and
    .repositories[0].imageScanningConfiguration.scanOnPush == true and
    .repositories[0].encryptionConfiguration.encryptionType == "AES256"
  ' <<<"$ecr_json" >/dev/null || fail 'ECR repository violates the reviewed contract'
ecr_tags_json="$(aws_read ecr list-tags-for-resource --resource-arn "$ECR_REPOSITORY_ARN")"
assert_expected_tags "$(jq -c '.tags' <<<"$ecr_tags_json")" 'ECR repository'
ecr_images_json="$(aws_read ecr list-images --repository-name "$ECR_REPOSITORY")"
jq -e '.imageIds | length == 0' <<<"$ecr_images_json" >/dev/null || fail 'ECR repository is not initially empty'

subnet_id="$(jq -er '.runner_subnet_id' <<<"$contract_json")"
security_group_id="$(jq -er '.runner_security_group_id' <<<"$contract_json")"
subnet_json="$(aws_read ec2 describe-subnets --subnet-ids "$subnet_id")"
jq -e --arg cidr "$SUBNET_CIDR" --arg az "$AVAILABILITY_ZONE" '
  (.Subnets | length) == 1 and
  .Subnets[0].CidrBlock == $cidr and
  .Subnets[0].AvailabilityZone == $az and
  .Subnets[0].MapPublicIpOnLaunch == false
' <<<"$subnet_json" >/dev/null || fail 'runner subnet violates the reviewed binding'
assert_expected_tags "$(jq -c '.Subnets[0].Tags' <<<"$subnet_json")" 'runner subnet'
vpc_id="$(jq -er '.Subnets[0].VpcId' <<<"$subnet_json")"

vpc_json="$(aws_read ec2 describe-vpcs --vpc-ids "$vpc_id")"
jq -e --arg cidr "$VPC_CIDR" '(.Vpcs | length) == 1 and .Vpcs[0].CidrBlock == $cidr' <<<"$vpc_json" >/dev/null ||
  fail 'runner VPC violates the reviewed binding'
assert_expected_tags "$(jq -c '.Vpcs[0].Tags' <<<"$vpc_json")" 'runner VPC'
vpc_dns_support_json="$(aws_read ec2 describe-vpc-attribute --vpc-id "$vpc_id" --attribute enableDnsSupport)"
jq -e '.EnableDnsSupport.Value == true' <<<"$vpc_dns_support_json" >/dev/null || fail 'runner VPC DNS support is disabled'
vpc_dns_hostnames_json="$(aws_read ec2 describe-vpc-attribute --vpc-id "$vpc_id" --attribute enableDnsHostnames)"
jq -e '.EnableDnsHostnames.Value == true' <<<"$vpc_dns_hostnames_json" >/dev/null || fail 'runner VPC DNS hostnames are disabled'

igw_json="$(aws_read ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${vpc_id}")"
jq -e '.InternetGateways | length == 1' <<<"$igw_json" >/dev/null || fail 'runner VPC does not have exactly one internet gateway'
internet_gateway_id="$(jq -er '.InternetGateways[0].InternetGatewayId' <<<"$igw_json")"
assert_expected_tags "$(jq -c '.InternetGateways[0].Tags' <<<"$igw_json")" 'runner internet gateway'

route_json="$(aws_read ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${subnet_id}")"
jq -e --arg gateway "$internet_gateway_id" '
  (.RouteTables | length) == 1 and
  ([.RouteTables[0].Routes[] | select(.DestinationCidrBlock == "0.0.0.0/0" and .GatewayId == $gateway)] | length) == 1
' <<<"$route_json" >/dev/null || fail 'runner subnet default route does not bind the platform internet gateway'
assert_expected_tags "$(jq -c '.RouteTables[0].Tags' <<<"$route_json")" 'runner route table'

security_group_json="$(aws_read ec2 describe-security-groups --group-ids "$security_group_id")"
jq -e --arg vpc "$vpc_id" '
  (.SecurityGroups | length) == 1 and
  .SecurityGroups[0].VpcId == $vpc and
  (.SecurityGroups[0].IpPermissions | length) == 0 and
  (.SecurityGroups[0].IpPermissionsEgress | length) == 1 and
  .SecurityGroups[0].IpPermissionsEgress[0].IpProtocol == "-1" and
  .SecurityGroups[0].IpPermissionsEgress[0].IpRanges == [{CidrIp:"0.0.0.0/0",Description:"Required provider and registry egress"}]
' <<<"$security_group_json" >/dev/null || fail 'runner security group is not no-ingress with the reviewed egress'
assert_expected_tags "$(jq -c '.SecurityGroups[0].Tags' <<<"$security_group_json")" 'runner security group'

deployer_role_json="$(aws_read iam get-role --role-name "$DEPLOYER_ROLE_NAME")"
jq -e --arg principal "$(jq -er '.binding.deployer_principal' "$REVIEW_RECEIPT")" '
  .Role.AssumeRolePolicyDocument.Statement == [{
    Action:"sts:AssumeRole",
    Effect:"Allow",
    Principal:{AWS:$principal},
    Sid:"ReviewedTemporaryPrincipalsOnly"
  }]
' <<<"$deployer_role_json" >/dev/null || fail 'deployer trust policy violates the reviewed binding'
assert_expected_tags "$(jq -c '.Role.Tags' <<<"$deployer_role_json")" 'deployer role'

publisher_role_json="$(aws_read iam get-role --role-name "$PUBLISHER_ROLE_NAME")"
jq -e --arg deployer "$DEPLOYER_ROLE_ARN" '
  .Role.AssumeRolePolicyDocument.Statement == [{
    Action:"sts:AssumeRole",
    Effect:"Allow",
    Principal:{AWS:$deployer},
    Sid:"ReviewedControlPrincipalsOnly"
  }]
' <<<"$publisher_role_json" >/dev/null || fail 'receipt publisher trust is not isolated to the deployer role'
assert_expected_tags "$(jq -c '.Role.Tags' <<<"$publisher_role_json")" 'receipt publisher role'

deployer_policy_json="$(aws_read iam get-role-policy --role-name "$DEPLOYER_ROLE_NAME" --policy-name "${RESOURCE_PREFIX}-disposable-runner-deployer")"
jq -e \
  --arg runner_state "${STATE_BUCKET_ARN}/aws/${ACCOUNT_ID}/${REGION}/runner/*" \
  --arg runner_role "arn:aws:iam::${ACCOUNT_ID}:role/${RESOURCE_PREFIX}-run-*" \
  --arg runtime "$RUNTIME_BOUNDARY_ARN" \
  --arg scheduler "$SCHEDULER_BOUNDARY_ARN" \
  --arg publisher "$PUBLISHER_ROLE_ARN" '
    def statement($sid): first(.PolicyDocument.Statement[] | select(.Sid == $sid));
    ([.PolicyDocument.Statement[].Sid] | sort) == ([
      "AssumeReceiptPublisherForControlPublication",
      "LaunchTaggedRunner",
      "ManageOnlyBoundedRunnerRoles",
      "ManageOnlyRunnerDeadlineSchedules",
      "ManageOnlyRunnerInstanceProfiles",
      "ManageTaggedRunnerLifecycle",
      "PassOnlyRunnerRolesToNativeServices",
      "ReadRunnerInfrastructure",
      "ReadWriteRunnerRemoteStateObjects",
      "RequireAcceptedRunnerBoundaries",
      "TagRunnerAtLaunch",
      "UseRunnerRemoteState"
    ] | sort) and
    statement("ReadWriteRunnerRemoteStateObjects").Resource == $runner_state and
    statement("ManageOnlyBoundedRunnerRoles").Resource == $runner_role and
    (statement("RequireAcceptedRunnerBoundaries").Condition.ArnEquals["iam:PermissionsBoundary"] | if type == "array" then sort else [.] end) == ([$runtime, $scheduler] | sort) and
    statement("AssumeReceiptPublisherForControlPublication").Resource == $publisher
  ' <<<"$deployer_policy_json" >/dev/null || fail 'live deployer policy violates the closed runner boundary'

publisher_policy_json="$(aws_read iam get-role-policy --role-name "$PUBLISHER_ROLE_NAME" --policy-name "${RESOURCE_PREFIX}-conditional-receipt-create")"
jq -e '
  ([.PolicyDocument.Statement[].Sid] | sort) == ([
    "ConditionallyCreateControlEvidenceAndReceipts",
    "ReadBoundedRunnerEvidence",
    "ReadResultsBucketLocation",
    "ReadRunnerDeadlineSchedule",
    "ReadRunnerLifecycleFacts"
  ] | sort) and
  (.PolicyDocument.Statement | tostring | contains("/runs/*/results/") | not)
' <<<"$publisher_policy_json" >/dev/null || fail 'live receipt publisher policy violates the bounded evidence contract'

get_managed_policy_document() {
  local policy_arn="$1"
  local policy_json version_id
  policy_json="$(aws_read iam get-policy --policy-arn "$policy_arn")"
  version_id="$(jq -er '.Policy.DefaultVersionId' <<<"$policy_json")"
  aws_read iam get-policy-version --policy-arn "$policy_arn" --version-id "$version_id" | jq -ec '.PolicyVersion.Document'
}

runtime_policy_meta_json="$(aws_read iam get-policy --policy-arn "$RUNTIME_BOUNDARY_ARN")"
assert_expected_tags "$(jq -c '.Policy.Tags' <<<"$runtime_policy_meta_json")" 'runtime boundary'
runtime_boundary_json="$(get_managed_policy_document "$RUNTIME_BOUNDARY_ARN")"
jq -e \
  --arg state "$STATE_BUCKET_ARN" \
  --arg results "$RESULTS_BUCKET_ARN" \
  --arg publisher "$PUBLISHER_ROLE_ARN" '
    def statement($sid): first(.Statement[] | select(.Sid == $sid));
    ([.Statement[].Sid] | sort) == ([
      "ConditionallyCreateOwnLocalReceiptHandoff",
      "DenyReceiptControlNamespace",
      "DenyReceiptPublisherAssumption",
      "DenyStateStorage",
      "GetECRAuthorizationToken",
      "ListGenericData",
      "PullCanonicalImageFromProviderLocalECR",
      "ReadGenericDataObjects",
      "ReadResultsBucketMetadata",
      "ReadRunSpecifications",
      "UseSystemsManagerControlChannels",
      "WriteOwnLogsAndResults"
    ] | sort) and
    (statement("DenyStateStorage").Resource | sort) == ([$state, $state + "/*"] | sort) and
    statement("DenyReceiptControlNamespace").Resource == ($results + "/control/*") and
    statement("DenyReceiptPublisherAssumption").Resource == $publisher
  ' <<<"$runtime_boundary_json" >/dev/null || fail 'live runtime boundary violates state or receipt isolation'

scheduler_policy_meta_json="$(aws_read iam get-policy --policy-arn "$SCHEDULER_BOUNDARY_ARN")"
assert_expected_tags "$(jq -c '.Policy.Tags' <<<"$scheduler_policy_meta_json")" 'scheduler boundary'
scheduler_boundary_json="$(get_managed_policy_document "$SCHEDULER_BOUNDARY_ARN")"
jq -e --arg project "$PROJECT_NAME" '
  .Statement == [{
    Action:"ec2:TerminateInstances",
    Condition:{StringEquals:{"ec2:ResourceTag/Project":$project}},
    Effect:"Allow",
    Resource:"*",
    Sid:"TerminateTaggedDemoRunner"
  }]
' <<<"$scheduler_boundary_json" >/dev/null || fail 'live scheduler boundary is not limited to tagged termination'

task_c_roles_json="$(aws_read iam list-roles --path-prefix /)"
jq -e --arg prefix "${RESOURCE_PREFIX}-run-" '[.Roles[] | select(.RoleName | startswith($prefix))] | length == 0' <<<"$task_c_roles_json" >/dev/null ||
  fail 'Task C runner roles already exist'
task_c_instances_json="$(aws_read ec2 describe-instances --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=tag:Root,Values=runner")"
jq -e '[.Reservations[].Instances[]] | length == 0' <<<"$task_c_instances_json" >/dev/null || fail 'Task C runner instances already exist'
task_c_schedules_json="$(aws_read scheduler list-schedules --name-prefix "${RESOURCE_PREFIX}-run-")"
jq -e '.Schedules | length == 0' <<<"$task_c_schedules_json" >/dev/null || fail 'Task C deadline schedules already exist'

printf 'validate-aws-platform-live: PASS\n'
