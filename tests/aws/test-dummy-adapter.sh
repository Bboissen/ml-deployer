#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${TEST_DIRECTORY}/../.." && pwd -P)"
readonly DISPATCH="${REPOSITORY_ROOT}/scripts/dummy/dispatch.sh"
readonly RUNTIME_PARENT="${REPOSITORY_ROOT}/.dummy-runtime"
mkdir -p -- "$RUNTIME_PARENT"
readonly TEST_ROOT="$(mktemp -d "${RUNTIME_PARENT}/aws-adapter-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'test-aws-dummy-adapter: FAIL: %s\n' "$1" >&2
  exit 1
}

for executable in \
  scripts/dummy/providers/aws.sh \
  scripts/aws/collect-dummy-readiness.sh \
  scripts/aws/dummy-publication.sh \
  scripts/aws/dummy-runner.sh \
  scripts/aws/prepare-dummy-receipt.sh \
  scripts/aws/dummy-receipt.sh \
  scripts/aws/validate-dummy-publisher-policy.sh; do
  [[ -x "${REPOSITORY_ROOT}/${executable}" ]] || fail "AWS lifecycle executable is missing: ${executable}"
done

for script in \
  scripts/aws/collect-dummy-readiness.sh scripts/aws/dummy-adapter-lib.sh \
  scripts/aws/dummy-publication.sh scripts/aws/dummy-runner.sh \
  scripts/aws/prepare-dummy-receipt.sh scripts/aws/dummy-receipt.sh \
  scripts/aws/validate-dummy-publisher-policy.sh \
  scripts/dummy/providers/aws.sh; do
  bash -n "${REPOSITORY_ROOT}/${script}" || fail "shell syntax failed: ${script}"
done

grep -Fq '/runs/*/results/result-manifest.json' "${REPOSITORY_ROOT}/infra/aws/platform/iam.tf" ||
  fail 'trusted publisher lacks canonical result-manifest read'
if grep -Fq '/runs/*/results/*' "${REPOSITORY_ROOT}/infra/aws/platform/iam.tf"; then
  fail 'trusted publisher can read arbitrary result objects'
fi
grep -Fq 'ExplicitlyDenyReceiptPublisherAssumption' "${REPOSITORY_ROOT}/infra/aws/runner/iam.tf" ||
  fail 'runner lacks explicit publisher-assumption deny'
grep -Fq 'assume_role {' "${REPOSITORY_ROOT}/infra/aws/runner/provider.tf" ||
  fail 'runner provider does not use the bounded deployer role'
grep -Fq 'aws_scheduler_schedule" "deadline' "${REPOSITORY_ROOT}/infra/aws/runner/main.tf" ||
  fail 'runner lacks a provider-side maximum-runtime safeguard'
if grep -Fq '/tmp/ml-runner' "${REPOSITORY_ROOT}/infra/aws/runner/templates/user-data.sh.tftpl"; then
  fail 'runner evidence uses /tmp'
fi
grep -Fq '/var/log/.ml-runner-bootstrap.tail.$$' \
  "${REPOSITORY_ROOT}/infra/aws/runner/templates/user-data.sh.tftpl" ||
  fail 'early bootstrap failures do not have a durable bounded log path'

for runner_plan_token in \
  'aws_iam_role_policy_attachment.ssm' \
  'actions:{create:8, update:0, delete:0, replace:0}' \
  'actions:{create:0, update:0, delete:8, replace:0}'; do
  grep -Fq "$runner_plan_token" "${REPOSITORY_ROOT}/scripts/aws/dummy-runner.sh" ||
    fail "runner saved-plan closure is missing ${runner_plan_token}"
done
for absence_code in InvalidInstanceID.NotFound NoSuchEntity ResourceNotFoundException; do
  grep -Fq "$absence_code" "${REPOSITORY_ROOT}/scripts/aws/dummy-runner.sh" ||
    fail "post-destroy check lacks exact absence classification for ${absence_code}"
done
grep -Fq "jq -j '.images[0].imageManifest'" "${REPOSITORY_ROOT}/scripts/aws/dummy-publication.sh" ||
  fail 'ECR manifest retrieval does not preserve exact bytes'
grep -Fq "'.images[0].imageId.imageDigest'" "${REPOSITORY_ROOT}/scripts/aws/dummy-publication.sh" ||
  fail 'ECR publication does not verify the returned digest'

for exact_key in \
  'control-input/execution-receipt.local.json' \
  'logs/bootstrap.log' \
  'results/result-manifest.json'; do
  grep -Fq "$exact_key" "${REPOSITORY_ROOT}/scripts/aws/prepare-dummy-receipt.sh" ||
    fail "publisher preparation is missing exact read: ${exact_key}"
done
if grep -Eq 'list-objects|results/\*|results/[^r].*\.json' \
    "${REPOSITORY_ROOT}/scripts/aws/prepare-dummy-receipt.sh"; then
  fail 'trusted publisher preparation contains an arbitrary results read'
fi

for readiness_token in \
  get-caller-identity get-service-quota get-parameter describe-instance-type-offerings \
  head-object list-object-versions get-bucket-policy describe-repositories list-schedules \
  describe-instance-information get-role-policy list-role-policies \
  list-attached-role-policies validate-dummy-publisher-policy.sh assume-role; do
  grep -Fq "$readiness_token" "${REPOSITORY_ROOT}/scripts/aws/collect-dummy-readiness.sh" ||
    fail "readiness collector is missing ${readiness_token}"
done
for readiness_shape_token in \
  "jq -cSj '.platform_contract.value'" \
  '.repositories | length == 1' \
  '([.Contents[]?] | length) == 0'; do
  grep -Fq "$readiness_shape_token" \
    "${REPOSITORY_ROOT}/scripts/aws/collect-dummy-readiness.sh" ||
    fail "readiness collector lacks current AWS response normalization: ${readiness_shape_token}"
done
platform_contract_fixture='{"provider":"aws","schema_version":"1.0.0"}'
platform_contract_hash="$(printf '%s' "$platform_contract_fixture" | sha256sum | cut -d' ' -f1)"
[[ "$(jq -cnj --argjson contract "$platform_contract_fixture" '$contract' | sha256sum | cut -d' ' -f1)" == \
  "$platform_contract_hash" ]] || fail 'platform contract canonical hash includes serialization whitespace'
jq -en '{repositories:[{imageTagMutability:"IMMUTABLE"}]}
  | .repositories | length == 1 and .[0].imageTagMutability == "IMMUTABLE"' >/dev/null ||
  fail 'current ECR response shape is rejected'
jq -en '{Prefix:"absent/"}
  | ([.Contents[]?] | length) == 0 and ([.CommonPrefixes[]?] | length) == 0' >/dev/null ||
  fail 'empty S3 prefix response without KeyCount is rejected'
if jq -en '{Contents:[{Key:"present"}]}
    | ([.Contents[]?] | length) == 0 and ([.CommonPrefixes[]?] | length) == 0' >/dev/null; then
  fail 'non-empty S3 prefix response was accepted as empty'
fi

if rg -F "AWS_PROFILE=''" \
    "${REPOSITORY_ROOT}/scripts/aws/collect-dummy-readiness.sh" \
    "${REPOSITORY_ROOT}/scripts/aws/prepare-dummy-receipt.sh" \
    "${REPOSITORY_ROOT}/scripts/aws/dummy-receipt.sh" >/dev/null; then
  fail 'temporary-role AWS calls select an invalid empty profile instead of unsetting profile variables'
fi
for temporary_role_script in \
  collect-dummy-readiness.sh prepare-dummy-receipt.sh dummy-receipt.sh; do
  grep -Fq 'unset AWS_PROFILE AWS_DEFAULT_PROFILE' \
    "${REPOSITORY_ROOT}/scripts/aws/${temporary_role_script}" ||
    fail "temporary-role AWS calls do not unset inherited profile selection: ${temporary_role_script}"
done

for gate_binding in \
  'dummy-publication.sh:aws_dummy_verify_exact_authorization PUBLICATION_AUTHORIZATION publish' \
  'dummy-runner.sh:aws_dummy_verify_exact_authorization APPLY_AUTHORIZATION apply' \
  'dummy-runner.sh:aws_dummy_verify_exact_authorization DESTROY_AUTHORIZATION destroy' \
  'dummy-receipt.sh:RECEIPT_PUBLISH_AUTHORIZATION receipt-publish'; do
  gate_script="${gate_binding%%:*}"
  gate_token="${gate_binding#*:}"
  grep -Fq "$gate_token" "${REPOSITORY_ROOT}/scripts/aws/${gate_script}" ||
    fail "direct AWS mutation entrypoint lacks exact authorization gate: ${gate_script}"
done

readonly POLICY_RESULTS_BUCKET=adapter-results-123456789012-us-east-1
readonly POLICY_RESULTS_ARN="arn:aws:s3:::${POLICY_RESULTS_BUCKET}"
readonly POLICY_PATH="${TEST_ROOT}/publisher-policy.json"
jq -n --arg results "$POLICY_RESULTS_ARN" '
  {PolicyDocument:{Version:"2012-10-17",Statement:[
    {Sid:"ReadRunnerLifecycleFacts",Effect:"Allow",Action:"ec2:DescribeInstances",Resource:"*"},
    {Sid:"ReadRunnerDeadlineSchedule",Effect:"Allow",Action:"scheduler:GetSchedule",
      Resource:"arn:aws:scheduler:us-east-1:123456789012:schedule/default/demo-run-*-stop"},
    {Sid:"ReadResultsBucketLocation",Effect:"Allow",Action:"s3:GetBucketLocation",Resource:$results},
    {Sid:"ReadBoundedRunnerEvidence",Effect:"Allow",Action:["s3:GetObjectVersion","s3:GetObject"],
      Resource:[$results+"/runs/*/results/result-manifest.json",$results+"/runs/*/logs/bootstrap.log",
        $results+"/runs/*/control-input/execution-receipt.local.json"]},
    {Sid:"ConditionallyCreateControlEvidenceAndReceipts",Effect:"Allow",Action:"s3:PutObject",
      Resource:[$results+"/control/receipts/*",$results+"/control/evidence/*"],
      Condition:{StringEquals:{"s3:if-none-match":"*"}}}
  ]}}
' >"$POLICY_PATH"
"${REPOSITORY_ROOT}/scripts/aws/validate-dummy-publisher-policy.sh" \
  "$POLICY_PATH" 123456789012 us-east-1 "$POLICY_RESULTS_BUCKET" demo >/dev/null ||
  fail 'exact closed publisher policy was rejected'
jq --arg results "$POLICY_RESULTS_ARN" '
  (.PolicyDocument.Statement[] | select(.Sid == "ReadBoundedRunnerEvidence") | .Resource)
    += [$results + "/runs/*/results/*"]
' "$POLICY_PATH" >"${TEST_ROOT}/publisher-policy-broad-read.json"
if "${REPOSITORY_ROOT}/scripts/aws/validate-dummy-publisher-policy.sh" \
    "${TEST_ROOT}/publisher-policy-broad-read.json" 123456789012 us-east-1 \
    "$POLICY_RESULTS_BUCKET" demo >/dev/null 2>&1; then
  fail 'publisher policy accepted an arbitrary results read'
fi
jq '.PolicyDocument.Statement += [{Sid:"UnexpectedAccess",Effect:"Allow",Action:"s3:*",Resource:"*"}]' \
  "$POLICY_PATH" >"${TEST_ROOT}/publisher-policy-extra-statement.json"
if "${REPOSITORY_ROOT}/scripts/aws/validate-dummy-publisher-policy.sh" \
    "${TEST_ROOT}/publisher-policy-extra-statement.json" 123456789012 us-east-1 \
    "$POLICY_RESULTS_BUCKET" demo >/dev/null 2>&1; then
  fail 'publisher policy accepted an extra wildcard statement'
fi

readonly MANIFEST_BYTES='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}'
jq -n --arg manifest "$MANIFEST_BYTES" \
  '{images:[{imageManifest:$manifest,imageId:{imageDigest:"sha256:unused"}}]}' \
  >"${TEST_ROOT}/batch-get-image.json"
jq -j '.images[0].imageManifest' "${TEST_ROOT}/batch-get-image.json" >"${TEST_ROOT}/manifest.raw"
[[ "$(sha256sum "${TEST_ROOT}/manifest.raw" | cut -d' ' -f1)" == \
  "$(printf '%s' "$MANIFEST_BYTES" | sha256sum | cut -d' ' -f1)" ]] ||
  fail 'ECR manifest extraction changed the returned bytes'

mkdir -p -- "${TEST_ROOT}/bin"
readonly MUTATION_MARKER="${TEST_ROOT}/mutation-called"
cat >"${TEST_ROOT}/bin/aws" <<EOF
#!/usr/bin/env bash
printf 'aws %s\n' "\$*" >>'${MUTATION_MARKER}'
exit 99
EOF
cat >"${TEST_ROOT}/bin/docker" <<EOF
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >>'${MUTATION_MARKER}'
exit 99
EOF
cat >"${TEST_ROOT}/bin/tofu" <<EOF
#!/usr/bin/env bash
printf 'tofu %s\n' "\$*" >>'${MUTATION_MARKER}'
exit 99
EOF
chmod 0755 "${TEST_ROOT}/bin/aws" "${TEST_ROOT}/bin/docker" "${TEST_ROOT}/bin/tofu"
readonly TEST_PATH="${TEST_ROOT}/bin:/usr/bin:/bin"

jq -n '{status:"SAVED_PLAN_READY_FOR_EXACT_APPLY_REVIEW", binding:{
  aws_account_id:"000000000000", aws_region:"us-east-1", state_bucket:"state-bucket",
  results_bucket:"results-bucket", data_bucket:"data-bucket", project_name:"demo",
  resource_prefix:"demo", ecr_repository:"demo/runner"}}' >"${TEST_ROOT}/task-b-review.json"
jq -n '{status:"TASK_B_ACCEPTED"}' >"${TEST_ROOT}/task-b-acceptance.json"
jq -n '{ecr_repository_url:{value:"000000000000.dkr.ecr.us-east-1.amazonaws.com/demo/runner"}}' \
  >"${TEST_ROOT}/platform-outputs.json"

common_environment=(
  AWS_PROFILE=test
  AWS_ACCOUNT_ID=000000000000
  AWS_REGION=us-east-1
  AWS_TASK_B_REVIEW="${TEST_ROOT}/task-b-review.json"
  AWS_TASK_B_ACCEPTANCE="${TEST_ROOT}/task-b-acceptance.json"
  AWS_PLATFORM_OUTPUTS="${TEST_ROOT}/platform-outputs.json"
  DEPLOYMENT_ID=aws-dummy-contract-test
)

printf 'sealed plan' >"${TEST_ROOT}/runner.tfplan"
plan_sha="$(sha256sum "${TEST_ROOT}/runner.tfplan" | cut -d' ' -f1)"
jq -n --arg sha "$plan_sha" '{schema_version:"1.0.0",operation:"apply",provider:"aws",
  artifact_sha256:$sha,authorization:("APPLY EXACT ARTIFACT sha256:"+$sha+" FOR aws")}' \
  >"${TEST_ROOT}/apply-authorization.json"
if env PATH="$TEST_PATH" "${common_environment[@]}" \
  SAVED_PLAN="${TEST_ROOT}/runner.tfplan" SAVED_PLAN_SHA256="$plan_sha" \
  APPLY_AUTHORIZATION="${TEST_ROOT}/apply-authorization.json" \
  "$DISPATCH" apply >/dev/null 2>&1; then
  fail 'authorized but unsealed runner plan was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'unsealed apply reached AWS/OpenTofu'
if env PATH="$TEST_PATH" "${common_environment[@]}" \
  SAVED_PLAN="${TEST_ROOT}/runner.tfplan" SAVED_PLAN_SHA256="$plan_sha" \
  "${REPOSITORY_ROOT}/scripts/aws/dummy-runner.sh" apply >/dev/null 2>&1; then
  fail 'direct runner apply without exact authorization was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'unauthorized direct runner apply reached AWS/OpenTofu'
if env PATH="$TEST_PATH" "${common_environment[@]}" \
  SAVED_PLAN="${TEST_ROOT}/runner.tfplan" SAVED_PLAN_SHA256="$plan_sha" \
  "${REPOSITORY_ROOT}/scripts/aws/dummy-runner.sh" destroy >/dev/null 2>&1; then
  fail 'direct runner destroy without exact authorization was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'unauthorized direct runner destroy reached AWS/OpenTofu'

package_lock_sha="$(sha256sum "${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke/requirements.lock" | cut -d' ' -f1)"
source_manifest_sha="$(sha256sum "${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke/image-source-manifest.json" | cut -d' ' -f1)"
run_spec_sha="$(sha256sum "${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke/run-spec.example.json" | cut -d' ' -f1)"
input_sha="$(sha256sum "${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke/fixtures/synthetic-input.parquet" | cut -d' ' -f1)"
manifest_hex="$(printf manifest | sha256sum | cut -d' ' -f1)"
jq -n '{schema_version:"1.0.0",operation:"publish",publication_kind:"input",
  scope:{provider:"aws",account_id:"000000000000",region:"us-east-1",deployment_id:"aws-dummy-contract-test"}}' \
  >"${TEST_ROOT}/wrong-publication.json"
publication_sha="$(sha256sum "${TEST_ROOT}/wrong-publication.json" | cut -d' ' -f1)"
jq -n --arg sha "$publication_sha" '{schema_version:"1.0.0",operation:"publish",provider:"aws",
  artifact_sha256:$sha,authorization:("PUBLISH EXACT ARTIFACT sha256:"+$sha+" FOR aws")}' \
  >"${TEST_ROOT}/publish-authorization.json"
if env PATH="$TEST_PATH" "${common_environment[@]}" \
  PACKAGE_LOCK_SHA256="$package_lock_sha" IMAGE_SOURCE_MANIFEST_SHA256="$source_manifest_sha" \
  OCI_MANIFEST_DIGEST="sha256:${manifest_hex}" RUN_SPEC_SHA256="$run_spec_sha" INPUT_SHA256="$input_sha" \
  AWS_PUBLICATION_KIND=input AWS_EVIDENCE_DIRECTORY="${TEST_ROOT}/publish-evidence" \
  PUBLICATION_BUNDLE="${TEST_ROOT}/wrong-publication.json" PUBLICATION_BUNDLE_SHA256="$publication_sha" \
  PUBLICATION_AUTHORIZATION="${TEST_ROOT}/publish-authorization.json" \
  "$DISPATCH" publish >/dev/null 2>&1; then
  fail 'wrong-account AWS publication binding was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'wrong publication binding reached AWS/Docker'
if env PATH="$TEST_PATH" "${common_environment[@]}" \
  PACKAGE_LOCK_SHA256="$package_lock_sha" IMAGE_SOURCE_MANIFEST_SHA256="$source_manifest_sha" \
  OCI_MANIFEST_DIGEST="sha256:${manifest_hex}" RUN_SPEC_SHA256="$run_spec_sha" INPUT_SHA256="$input_sha" \
  AWS_PUBLICATION_KIND=input PUBLICATION_BUNDLE="${TEST_ROOT}/wrong-publication.json" \
  PUBLICATION_BUNDLE_SHA256="$publication_sha" \
  "${REPOSITORY_ROOT}/scripts/aws/dummy-publication.sh" publish >/dev/null 2>&1; then
  fail 'direct AWS publication without exact authorization was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'unauthorized direct publication reached AWS/Docker'

jq -n --arg source "${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke/fixtures/synthetic-input.parquet" \
  --arg source_sha "$input_sha" \
  --argjson source_bytes "$(wc -c <"${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke/fixtures/synthetic-input.parquet")" \
  '{schema_version:"1.0.0",operation:"publish",publication_kind:"input",
    reviewed_at_utc:"2026-08-27T00:00:00Z",
    scope:{provider:"aws",account_id:"000000000000",region:"us-east-1",deployment_id:"aws-dummy-contract-test"},
    source:{path:$source,sha256:$source_sha,bytes:$source_bytes},
    target:{bucket:"wrong-bucket",key:"fixtures/tool-complete-dummy/wrong.parquet",
      uri:"s3://wrong-bucket/fixtures/tool-complete-dummy/wrong.parquet",
      publication_mode:"conditional_create",precondition:"object_absent",versioning:"enabled"}}
  ' >"${TEST_ROOT}/wrong-target-publication.json"
wrong_target_sha="$(sha256sum "${TEST_ROOT}/wrong-target-publication.json" | cut -d' ' -f1)"
jq -n --arg sha "$wrong_target_sha" '{schema_version:"1.0.0",operation:"publish",provider:"aws",
  artifact_sha256:$sha,authorization:("PUBLISH EXACT ARTIFACT sha256:"+$sha+" FOR aws")}' \
  >"${TEST_ROOT}/wrong-target-authorization.json"
if env PATH="$TEST_PATH" "${common_environment[@]}" \
  PACKAGE_LOCK_SHA256="$package_lock_sha" IMAGE_SOURCE_MANIFEST_SHA256="$source_manifest_sha" \
  OCI_MANIFEST_DIGEST="sha256:${manifest_hex}" RUN_SPEC_SHA256="$run_spec_sha" INPUT_SHA256="$input_sha" \
  AWS_PUBLICATION_KIND=input AWS_EVIDENCE_DIRECTORY="${TEST_ROOT}/wrong-target-evidence" \
  PUBLICATION_BUNDLE="${TEST_ROOT}/wrong-target-publication.json" PUBLICATION_BUNDLE_SHA256="$wrong_target_sha" \
  PUBLICATION_AUTHORIZATION="${TEST_ROOT}/wrong-target-authorization.json" \
  "$DISPATCH" publish >/dev/null 2>&1; then
  fail 'same-account publication binding with a different S3 target was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'wrong exact publication target reached AWS/Docker'

cp -- "${REPOSITORY_ROOT}/shared/contracts/fixtures/valid-aws.json" \
  "${TEST_ROOT}/receipt-runner-request.json"
jq '.deployment_id = "contract-smoke-001"' "${TEST_ROOT}/receipt-runner-request.json" \
  >"${TEST_ROOT}/receipt-runner-request.tmp.json"
mv -- "${TEST_ROOT}/receipt-runner-request.tmp.json" "${TEST_ROOT}/receipt-runner-request.json"
receipt_request_sha="$("${REPOSITORY_ROOT}/scripts/hash-runner-request.sh" \
  "${TEST_ROOT}/receipt-runner-request.json")"
jq --arg request_sha "$receipt_request_sha" '.request_sha256 = $request_sha' \
  "${REPOSITORY_ROOT}/shared/contracts/receipt-fixtures/valid-aws.json" \
  >"${TEST_ROOT}/completion-receipt.json"
jq -n --arg request_sha "$receipt_request_sha" '{
  deployment_id:{value:"contract-smoke-001"}, provider:{value:"aws"},
  runner_id:{value:"i-0123456789abcdef0"},
  workload_identity:{value:"arn:aws:iam::123456789012:role/ml-runner"},
  resolved_profile:{value:{requested:"smoke",provider_sku:"m7i.large",minimum_vcpu:2,minimum_memory_mib:8192}},
  deadline:{value:"2026-08-26T07:00:00Z"},
  results_uri:{value:"s3://ml-results-aws-example/runs/contract-smoke-001/results/"},
  receipt_uri:{value:"s3://ml-results-aws-example/control/receipts/contract-smoke-001/completion.v1.json"},
  request_sha256:{value:$request_sha},
  platform_contract_sha256:{value:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},
  backend_binding:{value:{bucket:"state",key:"aws/123456789012/us-east-1/runner/contract-smoke-001.tfstate",
    region:"us-east-1",use_lockfile:true}}
}' >"${TEST_ROOT}/receipt-runner-outputs.json"
jq -n '{
  deployer_role_arn:{value:"arn:aws:iam::123456789012:role/ml-tofu-deployer"},
  receipt_publisher_role_arn:{value:"arn:aws:iam::123456789012:role/ml-receipt-publisher"}
}' >"${TEST_ROOT}/receipt-platform-outputs.json"
printf 'wrong control evidence' >"${TEST_ROOT}/control-evidence.json"
completion_sha="$(sha256sum "${TEST_ROOT}/completion-receipt.json" | cut -d' ' -f1)"
jq -n --arg sha "$completion_sha" \
  '{schema_version:"1.0.0",provider:"aws",completion_receipt_sha256:$sha}' \
  >"${TEST_ROOT}/receipt-bundle.json"
receipt_bundle_sha="$(sha256sum "${TEST_ROOT}/receipt-bundle.json" | cut -d' ' -f1)"
jq -n --arg sha "$receipt_bundle_sha" '{schema_version:"1.0.0",operation:"receipt-publish",provider:"aws",
  artifact_sha256:$sha,authorization:("RECEIPT-PUBLISH EXACT ARTIFACT sha256:"+$sha+" FOR aws")}' \
  >"${TEST_ROOT}/receipt-authorization.json"
jq -n '{status:"SAVED_PLAN_READY_FOR_EXACT_APPLY_REVIEW", binding:{
  aws_account_id:"123456789012", aws_region:"us-east-1", results_bucket:"ml-results-aws-example",
  resource_prefix:"ml"}}' >"${TEST_ROOT}/receipt-task-b-review.json"
if env PATH="$TEST_PATH" AWS_PROFILE=test AWS_ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 \
  AWS_TASK_B_REVIEW="${TEST_ROOT}/receipt-task-b-review.json" \
  AWS_TASK_B_ACCEPTANCE="${TEST_ROOT}/task-b-acceptance.json" \
  AWS_PLATFORM_OUTPUTS="${TEST_ROOT}/receipt-platform-outputs.json" \
  RECEIPT_BUNDLE="${TEST_ROOT}/receipt-bundle.json" RECEIPT_BUNDLE_SHA256="$receipt_bundle_sha" \
  "${REPOSITORY_ROOT}/scripts/aws/dummy-receipt.sh" receipt-publish >/dev/null 2>&1; then
  fail 'direct receipt publication without exact authorization was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'unauthorized direct receipt publication reached AWS'
if env PATH="$TEST_PATH" AWS_PROFILE=test AWS_ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 \
  AWS_TASK_B_REVIEW="${TEST_ROOT}/receipt-task-b-review.json" \
  AWS_TASK_B_ACCEPTANCE="${TEST_ROOT}/task-b-acceptance.json" \
  AWS_PLATFORM_OUTPUTS="${TEST_ROOT}/receipt-platform-outputs.json" \
  DEPLOYMENT_ID=contract-smoke-001 AWS_EVIDENCE_DIRECTORY="${TEST_ROOT}/receipt-evidence" \
  AWS_RUNNER_REQUEST="${TEST_ROOT}/receipt-runner-request.json" \
  AWS_RUNNER_OUTPUTS="${TEST_ROOT}/receipt-runner-outputs.json" \
  AWS_COMPLETION_RECEIPT="${TEST_ROOT}/completion-receipt.json" \
  AWS_CONTROL_EVIDENCE="${TEST_ROOT}/control-evidence.json" \
  RECEIPT_BUNDLE="${TEST_ROOT}/receipt-bundle.json" RECEIPT_BUNDLE_SHA256="$receipt_bundle_sha" \
  RECEIPT_PUBLISH_AUTHORIZATION="${TEST_ROOT}/receipt-authorization.json" \
  "$DISPATCH" receipt-publish >/dev/null 2>&1; then
  fail 'receipt with mismatched control evidence was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'invalid receipt publication reached AWS'

jq '.oci_digest = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' \
  "${TEST_ROOT}/completion-receipt.json" >"${TEST_ROOT}/tampered-completion-receipt.json"
tampered_completion_sha="$(sha256sum "${TEST_ROOT}/tampered-completion-receipt.json" | cut -d' ' -f1)"
jq -n --arg sha "$tampered_completion_sha" \
  '{schema_version:"1.0.0",provider:"aws",completion_receipt_sha256:$sha}' \
  >"${TEST_ROOT}/tampered-receipt-bundle.json"
tampered_bundle_sha="$(sha256sum "${TEST_ROOT}/tampered-receipt-bundle.json" | cut -d' ' -f1)"
jq -n --arg sha "$tampered_bundle_sha" '{schema_version:"1.0.0",operation:"receipt-publish",provider:"aws",
  artifact_sha256:$sha,authorization:("RECEIPT-PUBLISH EXACT ARTIFACT sha256:"+$sha+" FOR aws")}' \
  >"${TEST_ROOT}/tampered-receipt-authorization.json"
if env PATH="$TEST_PATH" AWS_PROFILE=test AWS_ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 \
  AWS_TASK_B_REVIEW="${TEST_ROOT}/receipt-task-b-review.json" \
  AWS_TASK_B_ACCEPTANCE="${TEST_ROOT}/task-b-acceptance.json" \
  AWS_PLATFORM_OUTPUTS="${TEST_ROOT}/receipt-platform-outputs.json" \
  DEPLOYMENT_ID=contract-smoke-001 AWS_EVIDENCE_DIRECTORY="${TEST_ROOT}/tampered-receipt-evidence" \
  AWS_RUNNER_REQUEST="${TEST_ROOT}/receipt-runner-request.json" \
  AWS_RUNNER_OUTPUTS="${TEST_ROOT}/receipt-runner-outputs.json" \
  AWS_COMPLETION_RECEIPT="${TEST_ROOT}/tampered-completion-receipt.json" \
  AWS_CONTROL_EVIDENCE="${TEST_ROOT}/control-evidence.json" \
  RECEIPT_BUNDLE="${TEST_ROOT}/tampered-receipt-bundle.json" RECEIPT_BUNDLE_SHA256="$tampered_bundle_sha" \
  RECEIPT_PUBLISH_AUTHORIZATION="${TEST_ROOT}/tampered-receipt-authorization.json" \
  "$DISPATCH" receipt-publish >/dev/null 2>&1; then
  fail 'receipt differing from the sealed request was accepted'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'request-mismatched receipt reached AWS'

receipt_checksum="$(printf '%s' "$completion_sha" | xxd -r -p | base64 -w0)"
receipt_bytes="$(wc -c <"${TEST_ROOT}/completion-receipt.json")"
jq -n --arg checksum "$receipt_checksum" --arg sha "$completion_sha" \
  --argjson bytes "$receipt_bytes" '{
    publisher_caller:{Account:"999999999999",Arn:"arn:aws:sts::999999999999:assumed-role/other/session",UserId:"wrong"},
    control_put:{VersionId:"control-version"}, receipt_put:{VersionId:"receipt-version"},
    receipt_head:{VersionId:"receipt-version",ChecksumSHA256:$checksum,ContentLength:$bytes,
      Metadata:{"publisher-role":"arn:aws:iam::123456789012:role/ml-receipt-publisher",sha256:$sha}}
  }' >"${TEST_ROOT}/forged-provider-api.json"
forged_api_sha="$(sha256sum "${TEST_ROOT}/forged-provider-api.json" | cut -d' ' -f1)"
jq -n --arg receipt_sha "$completion_sha" --arg api_sha "$forged_api_sha" '{
  schema_version:"1.0.0",provider:"aws",deployment_id:"contract-smoke-001",
  published_at_utc:"2026-08-26T06:06:00Z",
  publisher_identity:"arn:aws:iam::123456789012:role/ml-receipt-publisher",
  receipt_object_version:"receipt-version",receipt_sha256:$receipt_sha,
  receipt_uri:"s3://ml-results-aws-example/control/receipts/contract-smoke-001/completion.v1.json",
  provider_api_evidence_sha256:$api_sha
}' >"${TEST_ROOT}/forged-publication-record.json"
if env PATH="$TEST_PATH" AWS_PROFILE=test AWS_ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 \
  AWS_TASK_B_REVIEW="${TEST_ROOT}/receipt-task-b-review.json" \
  AWS_TASK_B_ACCEPTANCE="${TEST_ROOT}/task-b-acceptance.json" \
  AWS_PLATFORM_OUTPUTS="${TEST_ROOT}/receipt-platform-outputs.json" \
  AWS_EVIDENCE_DIRECTORY="${TEST_ROOT}/receipt-check-evidence" \
  AWS_RUNNER_REQUEST="${TEST_ROOT}/receipt-runner-request.json" \
  AWS_RUNNER_OUTPUTS="${TEST_ROOT}/receipt-runner-outputs.json" \
  FINAL_RECEIPT="${TEST_ROOT}/completion-receipt.json" FINAL_RECEIPT_SHA256="$completion_sha" \
  AWS_RECEIPT_PUBLICATION_RECORD="${TEST_ROOT}/forged-publication-record.json" \
  AWS_RECEIPT_PUBLICATION_API_EVIDENCE="${TEST_ROOT}/forged-provider-api.json" \
  "$DISPATCH" receipt-check >/dev/null 2>&1; then
  fail 'receipt check accepted forged publisher identity evidence'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'forged receipt evidence reached live AWS verification'

printf 'test-aws-dummy-adapter: PASS\n'
