#!/usr/bin/env bash

set -euo pipefail

readonly PROVIDER_SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${PROVIDER_SCRIPT_DIRECTORY}/../../.." && pwd -P)"

# shellcheck disable=SC1091
source "${REPOSITORY_ROOT}/scripts/aws/dummy-adapter-lib.sh"

if (($# != 1)); then
  aws_dummy_fail 'usage: scripts/dummy/providers/aws.sh OPERATION'
fi

readonly OPERATION="$1"
aws_dummy_load_scope

case "$OPERATION" in
  preflight)
    aws_dummy_require_deployment
    aws_dummy_verify_common_bytes
    aws_dummy_require_task_b_evidence
    aws_dummy_prepare_fresh_evidence_directory
    set +e
    INPUT_SHA256="$INPUT_SHA256" RUN_SPEC_SHA256="$RUN_SPEC_SHA256" \
      "${REPOSITORY_ROOT}/scripts/aws/collect-dummy-readiness.sh" \
        "$AWS_EVIDENCE_DIRECTORY" \
        "$AWS_TASK_B_REVIEW" \
        "$AWS_TASK_B_ACCEPTANCE" \
        "$AWS_PLATFORM_OUTPUTS" \
        "$DEPLOYMENT_ID"
    readiness_exit=$?
    set -e
    if ((readiness_exit != 0)); then
      aws_dummy_fail "AWS readiness is blocked; inspect ${AWS_EVIDENCE_DIRECTORY}/readiness-summary.json"
    fi
    aws_dummy_emit_command_result \
      "${AWS_EVIDENCE_DIRECTORY}/command-result.json" \
      doctor null null aws.readiness 'AWS identity, capacity, lineage, persistent resources, prefixes and publisher boundary passed' \
      "${AWS_EVIDENCE_DIRECTORY}/readiness-summary.json"
    aws_dummy_write_sha256s "$AWS_EVIDENCE_DIRECTORY"
    jq -cS . "${AWS_EVIDENCE_DIRECTORY}/command-result.json"
    ;;
  publication-review|publish)
    exec "${REPOSITORY_ROOT}/scripts/aws/dummy-publication.sh" "$OPERATION"
    ;;
  plan|apply|observe|destroy-plan|destroy|post-destroy-check)
    exec "${REPOSITORY_ROOT}/scripts/aws/dummy-runner.sh" "$OPERATION"
    ;;
  receipt-publish|receipt-check)
    exec "${REPOSITORY_ROOT}/scripts/aws/dummy-receipt.sh" "$OPERATION"
    ;;
  *) aws_dummy_fail "unsupported operation: ${OPERATION}" ;;
esac
