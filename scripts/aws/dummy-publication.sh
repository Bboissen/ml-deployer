#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIRECTORY}/dummy-adapter-lib.sh"

if (($# != 1)); then
  aws_dummy_fail 'usage: scripts/aws/dummy-publication.sh publication-review|publish'
fi
readonly OPERATION="$1"
[[ "$OPERATION" == publication-review || "$OPERATION" == publish ]] ||
  aws_dummy_fail "unsupported publication operation: ${OPERATION}"

aws_dummy_require_command aws
aws_dummy_require_command base64
aws_dummy_require_command docker
aws_dummy_require_command jq
aws_dummy_require_command xxd
aws_dummy_require_deployment
aws_dummy_load_scope
aws_dummy_verify_common_bytes
aws_dummy_require_task_b_evidence
aws_dummy_require_env AWS_PUBLICATION_KIND
case "$AWS_PUBLICATION_KIND" in image|input|run-spec) ;; *) aws_dummy_fail 'AWS_PUBLICATION_KIND must be image, input, or run-spec' ;; esac

readonly RESULTS_BUCKET="$(jq -er '.binding.results_bucket' "$AWS_TASK_B_REVIEW")"
readonly DATA_BUCKET="$(jq -er '.binding.data_bucket' "$AWS_TASK_B_REVIEW")"
readonly ECR_REPOSITORY_NAME="$(jq -er '.binding.ecr_repository' "$AWS_TASK_B_REVIEW")"
readonly ECR_REPOSITORY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY_NAME}"
readonly IMAGE_TAG="dummy-${OCI_MANIFEST_DIGEST#sha256:}"
readonly IMAGE_TAG_SHORT="${IMAGE_TAG:0:18}"
readonly IMAGE_TARGET="${ECR_REPOSITORY}:${IMAGE_TAG_SHORT}"
readonly INPUT_KEY="fixtures/tool-complete-dummy/${INPUT_SHA256}.parquet"
readonly RUN_SPEC_KEY="run-specs/${DEPLOYMENT_ID}/${RUN_SPEC_SHA256}.json"
readonly RUN_SPEC_URI="s3://${RESULTS_BUCKET}/${RUN_SPEC_KEY}"
readonly CANONICAL_RUN_SPEC="${AWS_DUMMY_CANONICAL_ROOT}/run-spec.example.json"
readonly CANONICAL_INPUT="${AWS_DUMMY_CANONICAL_ROOT}/fixtures/synthetic-input.parquet"

write_common_publication_bundle() {
  local output_path="$1"
  local package_matrix_sha256 expected_output_sha256
  package_matrix_sha256="$(aws_dummy_file_sha256 "${AWS_DUMMY_CANONICAL_ROOT}/package-matrix.json")"
  expected_output_sha256="$(aws_dummy_file_sha256 "${AWS_DUMMY_CANONICAL_ROOT}/expected-output.json")"
  jq -cn \
    --arg package_lock_sha256 "$PACKAGE_LOCK_SHA256" \
    --arg package_matrix_sha256 "$package_matrix_sha256" \
    --arg image_source_manifest_sha256 "$IMAGE_SOURCE_MANIFEST_SHA256" \
    --arg oci_manifest_digest "$OCI_MANIFEST_DIGEST" \
    --arg run_spec_sha256 "$RUN_SPEC_SHA256" \
    --arg input_sha256 "$INPUT_SHA256" \
    --arg expected_output_policy_sha256 "$expected_output_sha256" '
    {
      schema_version:"1.0.0",
      provider:"aws",
      package_lock_sha256:$package_lock_sha256,
      package_matrix_sha256:$package_matrix_sha256,
      image_source_manifest_sha256:$image_source_manifest_sha256,
      oci_manifest_digest:$oci_manifest_digest,
      run_spec_sha256:$run_spec_sha256,
      input_sha256:$input_sha256,
      expected_output_policy_sha256:$expected_output_policy_sha256
    }
  ' >"$output_path"
}

review_image() {
  aws_dummy_require_env AWS_SOURCE_IMAGE
  aws_dummy_require_file AWS_OCI_MANIFEST_FILE
  [[ "sha256:$(aws_dummy_file_sha256 "$AWS_OCI_MANIFEST_FILE")" == "$OCI_MANIFEST_DIGEST" ]] ||
    aws_dummy_fail 'AWS_OCI_MANIFEST_FILE does not match OCI_MANIFEST_DIGEST'
  jq -e '.schemaVersion == 2' "$AWS_OCI_MANIFEST_FILE" >/dev/null ||
    aws_dummy_fail 'AWS_OCI_MANIFEST_FILE is not an OCI/Docker version 2 manifest'
  docker image inspect "$AWS_SOURCE_IMAGE" >"${AWS_EVIDENCE_DIRECTORY}/source-image.json"
  jq -e '. | length == 1 and .[0].Architecture == "amd64" and .[0].Os == "linux"' \
    "${AWS_EVIDENCE_DIRECTORY}/source-image.json" >/dev/null ||
    aws_dummy_fail 'AWS_SOURCE_IMAGE is not one local linux/amd64 image'
  aws_dummy_aws ecr describe-repositories --repository-names "$ECR_REPOSITORY_NAME" \
    >"${AWS_EVIDENCE_DIRECTORY}/ecr-repository.json"
  aws_dummy_aws ecr batch-get-image --repository-name "$ECR_REPOSITORY_NAME" \
    --image-ids "imageTag=${IMAGE_TAG_SHORT}" \
    >"${AWS_EVIDENCE_DIRECTORY}/target-image-before.json"
  jq -e '.images | length == 0' "${AWS_EVIDENCE_DIRECTORY}/target-image-before.json" >/dev/null ||
    aws_dummy_fail 'target ECR tag already exists and immutable publication is closed'
  readonly SOURCE_IMAGE_ID="$(jq -er '.[0].Id' "${AWS_EVIDENCE_DIRECTORY}/source-image.json")"
  jq -cn \
    --arg reviewed_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg account_id "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
    --arg deployment_id "$DEPLOYMENT_ID" --arg source_image "$AWS_SOURCE_IMAGE" \
    --arg source_image_id "$SOURCE_IMAGE_ID" --arg target "$IMAGE_TARGET" \
    --arg repository "$ECR_REPOSITORY" --arg repository_name "$ECR_REPOSITORY_NAME" \
    --arg tag "$IMAGE_TAG_SHORT" --arg oci_manifest_digest "$OCI_MANIFEST_DIGEST" \
    --arg oci_manifest_file_sha256 "$(aws_dummy_file_sha256 "$AWS_OCI_MANIFEST_FILE")" \
    --arg image_source_manifest_sha256 "$IMAGE_SOURCE_MANIFEST_SHA256" '
    {
      schema_version:"1.0.0", operation:"publish", publication_kind:"image",
      reviewed_at_utc:$reviewed_at_utc,
      scope:{provider:"aws", account_id:$account_id, region:$region, deployment_id:$deployment_id},
      source:{local_image:$source_image, local_image_id:$source_image_id,
        image_source_manifest_sha256:$image_source_manifest_sha256,
        oci_manifest_file_sha256:$oci_manifest_file_sha256},
      target:{repository:$repository, repository_name:$repository_name, tag:$tag,
        tagged_reference:$target, oci_manifest_digest:$oci_manifest_digest,
        repository_mutability:"IMMUTABLE", precondition:"tag_absent"}
    }
  ' >"${AWS_EVIDENCE_DIRECTORY}/aws-image-publication.json"
}

review_object() {
  local kind="$1"
  local bucket key source_file source_sha256 target_before
  case "$kind" in
    input)
      bucket="$DATA_BUCKET"
      key="$INPUT_KEY"
      source_file="$CANONICAL_INPUT"
      source_sha256="$INPUT_SHA256"
      ;;
    run-spec)
      bucket="$RESULTS_BUCKET"
      key="$RUN_SPEC_KEY"
      source_file="$CANONICAL_RUN_SPEC"
      source_sha256="$RUN_SPEC_SHA256"
      ;;
  esac
  target_before="${AWS_EVIDENCE_DIRECTORY}/target-object-before.json"
  aws_dummy_aws s3api list-objects-v2 --bucket "$bucket" --prefix "$key" >"$target_before"
  jq -e --arg key "$key" '([.Contents[]? | select(.Key == $key)] | length) == 0' \
    "$target_before" >/dev/null || aws_dummy_fail 'target S3 object already exists and conditional publication is closed'
  jq -cn \
    --arg reviewed_at_utc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg account_id "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
    --arg deployment_id "$DEPLOYMENT_ID" --arg publication_kind "$kind" \
    --arg source_file "$source_file" --arg source_sha256 "$source_sha256" \
    --argjson source_bytes "$(wc -c <"$source_file")" \
    --arg bucket "$bucket" --arg key "$key" --arg uri "s3://${bucket}/${key}" '
    {
      schema_version:"1.0.0", operation:"publish", publication_kind:$publication_kind,
      reviewed_at_utc:$reviewed_at_utc,
      scope:{provider:"aws", account_id:$account_id, region:$region, deployment_id:$deployment_id},
      source:{path:$source_file, sha256:$source_sha256, bytes:$source_bytes},
      target:{bucket:$bucket, key:$key, uri:$uri, publication_mode:"conditional_create",
        precondition:"object_absent", versioning:"enabled"}
    }
  ' >"${AWS_EVIDENCE_DIRECTORY}/aws-${kind}-publication.json"
}

if [[ "$OPERATION" == publication-review ]]; then
  aws_dummy_prepare_fresh_evidence_directory
  write_common_publication_bundle "${AWS_EVIDENCE_DIRECTORY}/publication-bundle.json"
  case "$AWS_PUBLICATION_KIND" in
    image) review_image ;;
    input|run-spec) review_object "$AWS_PUBLICATION_KIND" ;;
  esac
  aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
  binding_path="${AWS_EVIDENCE_DIRECTORY}/aws-${AWS_PUBLICATION_KIND}-publication.json"
  binding_sha256="$(aws_dummy_file_sha256 "$binding_path")"
  jq -cn \
    --arg status reviewed_not_authorized \
    --arg publication_kind "$AWS_PUBLICATION_KIND" \
    --arg binding_path "$binding_path" \
    --arg binding_sha256 "$binding_sha256" \
    --arg authorization "PUBLISH EXACT ARTIFACT sha256:${binding_sha256} FOR aws" '
    {status:$status, publication_kind:$publication_kind, binding_path:$binding_path,
      binding_sha256:$binding_sha256, exact_authorization_sentence:$authorization}
  '
  exit 0
fi

aws_dummy_verify_file_sha256 PUBLICATION_BUNDLE PUBLICATION_BUNDLE_SHA256
aws_dummy_verify_exact_authorization PUBLICATION_AUTHORIZATION publish "$PUBLICATION_BUNDLE_SHA256"
jq -e \
  --arg kind "$AWS_PUBLICATION_KIND" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
  --arg deployment "$DEPLOYMENT_ID" '
  .schema_version == "1.0.0" and .operation == "publish" and .publication_kind == $kind
  and .scope == {provider:"aws", account_id:$account, region:$region, deployment_id:$deployment}
' "$PUBLICATION_BUNDLE" >/dev/null || aws_dummy_fail 'PUBLICATION_BUNDLE is not the exact AWS publication binding'

case "$AWS_PUBLICATION_KIND" in
  image)
    aws_dummy_require_env AWS_SOURCE_IMAGE
    aws_dummy_require_file AWS_OCI_MANIFEST_FILE
    [[ "sha256:$(aws_dummy_file_sha256 "$AWS_OCI_MANIFEST_FILE")" == "$OCI_MANIFEST_DIGEST" ]] ||
      aws_dummy_fail 'AWS_OCI_MANIFEST_FILE no longer matches OCI_MANIFEST_DIGEST'
    current_source_image_id="$(docker image inspect "$AWS_SOURCE_IMAGE" --format '{{.Id}}')"
    jq -e \
      --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" --arg deployment "$DEPLOYMENT_ID" \
      --arg source_image "$AWS_SOURCE_IMAGE" --arg source_image_id "$current_source_image_id" \
      --arg image_source_manifest_sha256 "$IMAGE_SOURCE_MANIFEST_SHA256" \
      --arg oci_manifest_file_sha256 "$(aws_dummy_file_sha256 "$AWS_OCI_MANIFEST_FILE")" \
      --arg repository "$ECR_REPOSITORY" --arg repository_name "$ECR_REPOSITORY_NAME" \
      --arg tag "$IMAGE_TAG_SHORT" --arg target "$IMAGE_TARGET" --arg digest "$OCI_MANIFEST_DIGEST" '
      keys == ["operation", "publication_kind", "reviewed_at_utc", "schema_version", "scope", "source", "target"]
      and .schema_version == "1.0.0" and .operation == "publish" and .publication_kind == "image"
      and .scope == {provider:"aws", account_id:$account, region:$region, deployment_id:$deployment}
      and .source == {local_image:$source_image, local_image_id:$source_image_id,
        image_source_manifest_sha256:$image_source_manifest_sha256,
        oci_manifest_file_sha256:$oci_manifest_file_sha256}
      and .target == {repository:$repository, repository_name:$repository_name, tag:$tag,
        tagged_reference:$target, oci_manifest_digest:$digest,
        repository_mutability:"IMMUTABLE", precondition:"tag_absent"}
    ' "$PUBLICATION_BUNDLE" >/dev/null ||
      aws_dummy_fail 'image publication binding differs from the current reviewed source or exact ECR target'
    ;;
  input|run-spec)
    if [[ "$AWS_PUBLICATION_KIND" == input ]]; then
      source_file="$CANONICAL_INPUT"; source_sha256="$INPUT_SHA256"; bucket="$DATA_BUCKET"; key="$INPUT_KEY"
    else
      source_file="$CANONICAL_RUN_SPEC"; source_sha256="$RUN_SPEC_SHA256"; bucket="$RESULTS_BUCKET"; key="$RUN_SPEC_KEY"
    fi
    jq -e \
      --arg kind "$AWS_PUBLICATION_KIND" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
      --arg deployment "$DEPLOYMENT_ID" --arg source_file "$source_file" \
      --arg source_sha256 "$source_sha256" --argjson source_bytes "$(wc -c <"$source_file")" \
      --arg bucket "$bucket" --arg key "$key" --arg uri "s3://${bucket}/${key}" '
      keys == ["operation", "publication_kind", "reviewed_at_utc", "schema_version", "scope", "source", "target"]
      and .schema_version == "1.0.0" and .operation == "publish" and .publication_kind == $kind
      and .scope == {provider:"aws", account_id:$account, region:$region, deployment_id:$deployment}
      and .source == {path:$source_file, sha256:$source_sha256, bytes:$source_bytes}
      and .target == {bucket:$bucket, key:$key, uri:$uri, publication_mode:"conditional_create",
        precondition:"object_absent", versioning:"enabled"}
    ' "$PUBLICATION_BUNDLE" >/dev/null ||
      aws_dummy_fail 'object publication binding differs from the accepted bytes or exact S3 target'
    ;;
esac
aws_dummy_prepare_fresh_evidence_directory

case "$AWS_PUBLICATION_KIND" in
  image)
    aws_dummy_aws ecr batch-get-image --repository-name "$ECR_REPOSITORY_NAME" \
      --image-ids "imageTag=${IMAGE_TAG_SHORT}" >"${AWS_EVIDENCE_DIRECTORY}/target-image-before.json"
    jq -e '.images | length == 0' "${AWS_EVIDENCE_DIRECTORY}/target-image-before.json" >/dev/null ||
      aws_dummy_fail 'target ECR tag appeared after review'
    aws ecr get-login-password --profile "$AWS_PROFILE" --region "$AWS_REGION" |
      docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null
    docker tag "$AWS_SOURCE_IMAGE" "$IMAGE_TARGET"
    docker push "$IMAGE_TARGET" >"${AWS_EVIDENCE_DIRECTORY}/docker-push.txt"
    docker logout "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null 2>&1 || true
    aws_dummy_aws ecr batch-get-image --repository-name "$ECR_REPOSITORY_NAME" \
      --image-ids "imageTag=${IMAGE_TAG_SHORT}" \
      --accepted-media-types application/vnd.oci.image.manifest.v1+json application/vnd.docker.distribution.manifest.v2+json \
      >"${AWS_EVIDENCE_DIRECTORY}/published-image.json"
    jq -j '.images[0].imageManifest' "${AWS_EVIDENCE_DIRECTORY}/published-image.json" \
      >"${AWS_EVIDENCE_DIRECTORY}/oci-manifest.json"
    [[ "$(jq -er '.images[0].imageId.imageDigest' "${AWS_EVIDENCE_DIRECTORY}/published-image.json")" == "$OCI_MANIFEST_DIGEST" ]] ||
      aws_dummy_fail 'ECR returned a different image digest after publication'
    [[ "sha256:$(aws_dummy_file_sha256 "${AWS_EVIDENCE_DIRECTORY}/oci-manifest.json")" == "$OCI_MANIFEST_DIGEST" ]] ||
      aws_dummy_fail 'published ECR manifest differs from the reviewed OCI manifest digest'
    ;;
  input|run-spec)
    aws_dummy_aws s3api list-objects-v2 --bucket "$bucket" --prefix "$key" \
      >"${AWS_EVIDENCE_DIRECTORY}/target-object-before.json"
    jq -e '([.Contents[]?] | length) == 0' "${AWS_EVIDENCE_DIRECTORY}/target-object-before.json" >/dev/null ||
      aws_dummy_fail 'target S3 object appeared after review'
    checksum_base64="$(aws_dummy_file_sha256 "$source_file" | xxd -r -p | base64 -w0)"
    aws_dummy_aws s3api put-object --bucket "$bucket" --key "$key" --body "$source_file" \
      --if-none-match '*' --checksum-algorithm SHA256 --checksum-sha256 "$checksum_base64" \
      >"${AWS_EVIDENCE_DIRECTORY}/put-object.json"
    aws_dummy_aws s3api head-object --bucket "$bucket" --key "$key" \
      --version-id "$(jq -er '.VersionId' "${AWS_EVIDENCE_DIRECTORY}/put-object.json")" \
      >"${AWS_EVIDENCE_DIRECTORY}/published-object.json"
    [[ "$(jq -er '.ChecksumSHA256' "${AWS_EVIDENCE_DIRECTORY}/published-object.json")" == "$checksum_base64" ]] ||
      aws_dummy_fail 'published S3 checksum differs from the reviewed source bytes'
    ;;
esac

cp -- "$PUBLICATION_BUNDLE" "${AWS_EVIDENCE_DIRECTORY}/authorized-aws-publication-binding.json"
cp -- "$PUBLICATION_AUTHORIZATION" "${AWS_EVIDENCE_DIRECTORY}/publication-authorization.json"
aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
jq -cn \
  --arg status published --arg publication_kind "$AWS_PUBLICATION_KIND" \
  --arg deployment_id "$DEPLOYMENT_ID" --arg evidence_directory "$AWS_EVIDENCE_DIRECTORY" \
  --arg run_spec_uri "$RUN_SPEC_URI" '
  {schema_version:"1.0.0", status:$status, provider:"aws", publication_kind:$publication_kind,
    deployment_id:$deployment_id, run_spec_uri:$run_spec_uri, evidence_directory:$evidence_directory}
'
