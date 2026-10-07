#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${TEST_DIRECTORY}/../.." && pwd -P)"
readonly VALIDATOR="${REPOSITORY_ROOT}/scripts/dummy/validate-cross-cloud-acceptance.sh"
readonly WORKLOAD_ROOT="${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke"
readonly TEST_PARENT="${REPOSITORY_ROOT}/evidence/.test-runtime"
mkdir -p "$TEST_PARENT"
readonly TEST_ROOT="$(mktemp -d "${TEST_PARENT}/acceptance-test.XXXXXX")"
trap 'find "$TEST_ROOT" -depth -delete' EXIT

fail() {
  printf 'test-cross-cloud-acceptance: FAIL: %s\n' "$1" >&2
  exit 1
}

file_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

write_authorization() {
  local provider="$1"
  local operation="$2"
  local artifact="$3"
  local destination="$4"
  local artifact_sha256
  artifact_sha256="$(file_sha256 "$artifact")"
  jq -cn \
    --arg operation "$operation" \
    --arg provider "$provider" \
    --arg artifact_sha256 "$artifact_sha256" \
    --arg authorization "${operation^^} EXACT ARTIFACT sha256:${artifact_sha256} FOR ${provider}" '
    {
      artifact_sha256: $artifact_sha256,
      authorization: $authorization,
      operation: $operation,
      provider: $provider,
      schema_version: "1.0.0"
    }' >"$destination"
}

content_type() {
  case "$1" in
    *.parquet) printf 'application/vnd.apache.parquet\n' ;;
    *.md) printf 'text/markdown\n' ;;
    *) printf 'application/json\n' ;;
  esac
}

build_provider_evidence() {
  local provider="$1"
  local provider_root="${TEST_ROOT}/evidence/${provider}"
  local results_root="${provider_root}/results"
  local run_spec_sha256 input_sha256 policy_sha256 lock_sha256 matrix_sha256 source_sha256
  local oci_digest entries relative artifact bytes artifact_sha manifest_sha receipt_sha
  local deployment_id receipt_uri publisher_identity api_sha destroy_api_sha mlflow_run_id
  local feature_hash fold_hash schema_hash

  mkdir -p "$results_root"
  install -m 0444 "${WORKLOAD_ROOT}/requirements.lock" "${provider_root}/requirements.lock"
  install -m 0444 "${WORKLOAD_ROOT}/package-matrix.json" "${provider_root}/package-matrix.json"
  install -m 0444 "${WORKLOAD_ROOT}/image-source-manifest.json" "${provider_root}/image-source-manifest.json"
  install -m 0444 "${WORKLOAD_ROOT}/run-spec.example.json" "${provider_root}/run-spec.json"
  install -m 0444 "${WORKLOAD_ROOT}/fixtures/synthetic-input.parquet" "${provider_root}/synthetic-input.parquet"
  install -m 0444 "${WORKLOAD_ROOT}/expected-output.json" "${provider_root}/expected-output.json"
  printf '%s\n' '{"config":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"layers":[],"schemaVersion":2}' \
    >"${provider_root}/oci-manifest.json"

  run_spec_sha256="$(file_sha256 "${provider_root}/run-spec.json")"
  input_sha256="$(file_sha256 "${provider_root}/synthetic-input.parquet")"
  policy_sha256="$(file_sha256 "${provider_root}/expected-output.json")"
  lock_sha256="$(file_sha256 "${provider_root}/requirements.lock")"
  matrix_sha256="$(file_sha256 "${provider_root}/package-matrix.json")"
  source_sha256="$(file_sha256 "${provider_root}/image-source-manifest.json")"
  oci_digest="sha256:$(file_sha256 "${provider_root}/oci-manifest.json")"
  feature_hash="$(printf feature-set | sha256sum | cut -d' ' -f1)"
  fold_hash="$(printf fold-definition | sha256sum | cut -d' ' -f1)"
  schema_hash="$(printf schema | sha256sum | cut -d' ' -f1)"
  case "$provider" in
    aws) mlflow_run_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
    gcp) mlflow_run_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
    azure) mlflow_run_id="cccccccccccccccccccccccccccccccc" ;;
  esac

  entries='[]'
  while IFS= read -r relative; do
    artifact="${results_root}/${relative}"
    mkdir -p "$(dirname "$artifact")"
    case "$relative" in
      metrics/metrics.json)
        jq -cn \
          --arg run_spec_sha256 "$run_spec_sha256" \
          --arg input_sha256 "$input_sha256" \
          --slurpfile policy "${provider_root}/expected-output.json" '
          {
            fixture_bytes: 4991,
            fixture_sha256: $input_sha256,
            logical_results: $policy[0].exact_logical_results,
            metrics: {
              calibration: {brier: 0.1, curve_predicted: [0.1, 0.9], curve_true: [0.0, 1.0]},
              models: {
                catboost_rmse: 1.0,
                lightgbm_rmse: 1.0,
                linear_rmse: 0.1,
                statsmodels_r_squared: 0.999,
                xgboost_rmse: 1.0
              },
              optuna: {best_value: 0.01, trials: 1},
              ray_tune: {best_loss: 0.0, trials: 1},
              simulation: {draws: 128, mean: 0.0, p05: -1.0, p95: 1.0}
            },
            run_spec_sha256: $run_spec_sha256,
            schema_version: "1.0.0",
            workload: "tool-complete-dummy"
          }' >"$artifact"
        ;;
      packages/versions.json)
        jq -c 'reduce .packages[] as $package ({}; .[$package.distribution] = $package.version)' \
          "${provider_root}/package-matrix.json" >"$artifact"
        ;;
      explanations/shap.json)
        jq -cn '
          {
            additivity_max_abs_error: 0.0,
            background_rows: 48,
            explained_output: "regression_value",
            explained_rows: 4,
            explainer: "LinearExplainer",
            mean_absolute_attribution: {feature_a: 0.1, feature_b: 0.2, feature_c: 0.3},
            non_causal: true
          }' >"$artifact"
        ;;
      models/linear-model.json)
        jq -cn '
          {
            coefficients: [1.0, 2.0, 3.0],
            family: "sklearn-linear-regression",
            feature_names: ["feature_a", "feature_b", "feature_c"],
            intercept: 0.0,
            purpose: "synthetic-shape-only"
          }' >"$artifact"
        ;;
      tracking/mlflow-artifact-tracking.json)
        jq -cn --arg input_sha256 "$input_sha256" '
          {
            artifact_roots: ["explanations", "models", "recovery"],
            backend: "ephemeral-local-sqlite",
            dataset_digest_bound: true,
            dataset_digest_projection: ("sha256:" + $input_sha256[0:29]),
            dataset_full_sha256_parameter_bound: true,
            dataset_source_is_provider_local: true,
            explicit_metrics_logged: true,
            nested_runs_enabled: false,
            persistent_service_ready: false,
            run_count: 1,
            run_finished: true,
            system_metrics_enabled: false
          }' >"$artifact"
        ;;
      run-manifest.json)
        jq -cn \
          --arg run_spec_sha256 "$run_spec_sha256" \
          --arg input_sha256 "$input_sha256" \
          --arg lock_sha256 "$lock_sha256" \
          --arg oci_digest "$oci_digest" \
          --arg run_id "$mlflow_run_id" \
          --arg feature_hash "$feature_hash" \
          --arg fold_hash "$fold_hash" \
          --arg schema_hash "$schema_hash" '
          {
            candidate_generator_version: "not-applicable-synthetic",
            checkpoint: "synthetic",
            config_hash: $run_spec_sha256,
            dataset_manifest_hash: $input_sha256,
            dataset_snapshot_id: ("synthetic-" + $input_sha256[0:12]),
            environment_lock_hash: $lock_sha256,
            feature_set_hash: $feature_hash,
            fold_definition_hash: $fold_hash,
            git_commit: "bound-by-reviewed-image-source-manifest",
            gold_schema_hash: $schema_hash,
            image_digest: $oci_digest,
            mlflow_run_id: $run_id,
            mlflow_sync_status: "ephemeral-local-verified",
            mlflow_tracking_uri_identity: "ephemeral-local-sqlite",
            model_family: "bounded-multi-family-smoke",
            region: "synthetic",
            run_id: $run_id,
            schema_version: "1.0.0",
            seed: 20260827
          }' >"$artifact"
        ;;
      checkpoints/final.json)
        jq -cn --arg run_spec_sha256 "$run_spec_sha256" --arg input_sha256 "$input_sha256" '
          {
            completed_stages: [
              "input-validation", "columnar-transforms", "model-families", "bounded-optuna",
              "single-node-ray-tune", "mlflow-polars-dataset-lineage",
              "mlflow-explicit-metrics-and-artifacts", "recovery-run-manifest", "shap",
              "calibration", "simulation"
            ],
            fixture_sha256: $input_sha256,
            recoverable_training_claim: false,
            run_spec_sha256: $run_spec_sha256,
            schema_version: "1.0.0"
          }' >"$artifact"
        ;;
      data/transformed.parquet)
        install -m 0444 "${TEST_DIRECTORY}/fixtures/expected-transformed.parquet" "$artifact"
        ;;
      reports/conformance.md)
        printf '# Tool-complete dummy workload\n\nCPU-only, single-node process shape.\nRun: %s\nInput: %s\n' \
          "$run_spec_sha256" "$input_sha256" >"$artifact"
        ;;
      *) fail "test generator does not implement artifact: ${relative}" ;;
    esac
    bytes="$(wc -c <"$artifact")"
    artifact_sha="$(file_sha256 "$artifact")"
    entries="$(jq -cn \
      --argjson entries "$entries" \
      --arg path "$relative" \
      --arg content_type "$(content_type "$relative")" \
      --argjson bytes "$bytes" \
      --arg sha256 "$artifact_sha" \
      '$entries + [{bytes: $bytes, content_type: $content_type, path: $path, sha256: $sha256}]')"
  done < <(jq -r '.required_artifacts[]' "${provider_root}/expected-output.json")

  jq -cn \
    --argjson artifacts "$entries" \
    --arg run_spec_sha256 "$run_spec_sha256" '
    {
      artifacts: $artifacts,
      run_spec_sha256: $run_spec_sha256,
      schema_version: "1.0.0",
      workload: "tool-complete-dummy"
    }' >"${provider_root}/result-manifest.json"
  manifest_sha="$(file_sha256 "${provider_root}/result-manifest.json")"

  jq \
    --arg run_spec_sha256 "$run_spec_sha256" \
    --arg oci_digest "$oci_digest" \
    --arg result_manifest_sha256 "$manifest_sha" '
      .run_spec_sha256 = $run_spec_sha256
      | .run_spec_uri |= sub("[0-9a-f]{64}\\.json$"; $run_spec_sha256 + ".json")
      | .oci_digest = $oci_digest
      | .result_manifest_sha256 = $result_manifest_sha256
    ' "${REPOSITORY_ROOT}/shared/contracts/receipt-fixtures/valid-${provider}.json" \
    >"${provider_root}/completion-receipt.json"
  receipt_sha="$(file_sha256 "${provider_root}/completion-receipt.json")"

  jq -cn \
    --arg provider "$provider" \
    --arg lock "$lock_sha256" \
    --arg matrix "$matrix_sha256" \
    --arg source "$source_sha256" \
    --arg oci "$oci_digest" \
    --arg run "$run_spec_sha256" \
    --arg input "$input_sha256" \
    --arg policy "$policy_sha256" '
    {
      expected_output_policy_sha256: $policy,
      image_source_manifest_sha256: $source,
      input_sha256: $input,
      oci_manifest_digest: $oci,
      package_lock_sha256: $lock,
      package_matrix_sha256: $matrix,
      provider: $provider,
      run_spec_sha256: $run,
      schema_version: "1.0.0"
    }' >"${provider_root}/publication-bundle.json"
  printf 'saved apply plan for %s\n' "$provider" >"${provider_root}/apply-plan.bin"
  jq -cn --arg provider "$provider" --arg receipt_sha "$receipt_sha" '
    {completion_receipt_sha256: $receipt_sha, provider: $provider, schema_version: "1.0.0"}' \
    >"${provider_root}/receipt-bundle.json"
  printf 'saved destroy plan for %s\n' "$provider" >"${provider_root}/destroy-plan.bin"

  write_authorization "$provider" publish "${provider_root}/publication-bundle.json" \
    "${provider_root}/publication-authorization.json"
  write_authorization "$provider" apply "${provider_root}/apply-plan.bin" \
    "${provider_root}/apply-authorization.json"
  write_authorization "$provider" receipt-publish "${provider_root}/receipt-bundle.json" \
    "${provider_root}/receipt-publish-authorization.json"
  write_authorization "$provider" destroy "${provider_root}/destroy-plan.bin" \
    "${provider_root}/destroy-authorization.json"

  jq -cn --arg provider "$provider" '{provider: $provider, verified: true}' \
    >"${provider_root}/receipt-publication-provider-api.json"
  api_sha="$(file_sha256 "${provider_root}/receipt-publication-provider-api.json")"
  deployment_id="$(jq -er '.deployment_id' "${provider_root}/completion-receipt.json")"
  receipt_uri="$(jq -er '.receipt_uri' "${provider_root}/completion-receipt.json")"
  publisher_identity="$(jq -er '.receipt_publisher_identity' "${provider_root}/completion-receipt.json")"
  jq -cn \
    --arg provider "$provider" \
    --arg deployment_id "$deployment_id" \
    --arg api_sha "$api_sha" \
    --arg publisher_identity "$publisher_identity" \
    --arg receipt_sha "$receipt_sha" \
    --arg receipt_uri "$receipt_uri" '
    {
      deployment_id: $deployment_id,
      provider: $provider,
      provider_api_evidence_sha256: $api_sha,
      published_at_utc: "2026-08-27T12:00:00Z",
      publisher_identity: $publisher_identity,
      receipt_object_version: "test-version-1",
      receipt_sha256: $receipt_sha,
      receipt_uri: $receipt_uri,
      schema_version: "1.0.0"
    }' >"${provider_root}/receipt-publication.json"

  jq -cn --arg provider "$provider" '{provider: $provider, runner_count: 0}' \
    >"${provider_root}/post-destroy-provider-api.json"
  destroy_api_sha="$(file_sha256 "${provider_root}/post-destroy-provider-api.json")"
  jq -cn \
    --arg provider "$provider" \
    --arg deployment_id "$deployment_id" \
    --arg api_sha "$destroy_api_sha" '
    {
      checked_at_utc: "2026-08-27T12:05:00Z",
      deployment_id: $deployment_id,
      persistent_storage_retained: true,
      provider: $provider,
      provider_api_evidence_sha256: $api_sha,
      runner_absent: true,
      runner_state_absent: true,
      schema_version: "1.0.0"
  }' >"${provider_root}/post-destroy.json"
}

reseal_result_artifact() {
  local provider="$1"
  local relative="$2"
  local provider_root="${TEST_ROOT}/evidence/${provider}"
  local artifact="${provider_root}/results/${relative}"
  local manifest="${provider_root}/result-manifest.json"
  local updated="${provider_root}/result-manifest.updated.json"
  local bytes artifact_sha
  bytes="$(wc -c <"$artifact")"
  artifact_sha="$(file_sha256 "$artifact")"
  jq \
    --arg path "$relative" \
    --argjson bytes "$bytes" \
    --arg sha256 "$artifact_sha" '
      (.artifacts[] | select(.path == $path)) |= (.bytes = $bytes | .sha256 = $sha256)
    ' "$manifest" >"$updated"
  mv -- "$updated" "$manifest"
}

assert_semantic_rejected() {
  local label="$1"
  local expected_message="$2"
  local error_path="${TEST_ROOT}/${label}.stderr"
  if "$VALIDATOR" "${TEST_ROOT}/evidence" >/dev/null 2>"$error_path"; then
    fail "${label} evidence was accepted"
  fi
  grep -Fq "$expected_message" "$error_path" ||
    fail "${label} evidence failed for the wrong reason"
}

[[ "$(file_sha256 "${TEST_DIRECTORY}/fixtures/expected-transformed.parquet")" == \
   "$(jq -er '.exact_artifact_sha256["data/transformed.parquet"]' "${WORKLOAD_ROOT}/expected-output.json")" ]] ||
  fail "expected transformed Parquet fixture does not match the frozen policy"

mkdir -p "${TEST_ROOT}/summary-only"
for provider in aws gcp azure; do
  mkdir -p "${TEST_ROOT}/summary-only/${provider}"
  printf '%s\n' '{"provider":"fabricated","receipt_verified":true,"runner_destroyed":true}' \
    >"${TEST_ROOT}/summary-only/${provider}/acceptance-receipt.json"
done
if "$VALIDATOR" "${TEST_ROOT}/summary-only" >/dev/null 2>&1; then
  fail "self-asserted acceptance summaries were accepted"
fi

for provider in aws gcp azure; do
  build_provider_evidence "$provider"
done
"$VALIDATOR" "${TEST_ROOT}/evidence" >/dev/null || fail "complete bound evidence was rejected"

jq '.packages[0].distribution = "not-the-reviewed-package"' \
  "${TEST_ROOT}/evidence/gcp/package-matrix.json" >"${TEST_ROOT}/matrix.invalid.json"
mv -- "${TEST_ROOT}/matrix.invalid.json" "${TEST_ROOT}/evidence/gcp/package-matrix.json"
assert_semantic_rejected altered-matrix 'package matrix does not match the reviewed common bytes'
build_provider_evidence gcp

chmod 0644 "${TEST_ROOT}/evidence/gcp/results/data/transformed.parquet"
printf 'PAR1garbagePAR1' >"${TEST_ROOT}/evidence/gcp/results/data/transformed.parquet"
reseal_result_artifact gcp data/transformed.parquet
assert_semantic_rejected corrupt-parquet 'transformed Parquet does not match the exact output policy'
build_provider_evidence gcp

printf '%s\n' '{"numpy":"2.5.2"}' >"${TEST_ROOT}/evidence/gcp/results/packages/versions.json"
reseal_result_artifact gcp packages/versions.json
assert_semantic_rejected incomplete-packages 'package inventory does not match the frozen matrix'
build_provider_evidence gcp

jq '.metrics = {smoke_value: 1.0}' "${TEST_ROOT}/evidence/gcp/results/metrics/metrics.json" \
  >"${TEST_ROOT}/metrics.invalid.json"
mv -- "${TEST_ROOT}/metrics.invalid.json" "${TEST_ROOT}/evidence/gcp/results/metrics/metrics.json"
reseal_result_artifact gcp metrics/metrics.json
assert_semantic_rejected incomplete-metrics 'metrics do not satisfy the frozen smoke policy'
build_provider_evidence gcp

jq '.metrics.models.linear_rmse = -1' "${TEST_ROOT}/evidence/gcp/results/metrics/metrics.json" \
  >"${TEST_ROOT}/metrics.invalid.json"
mv -- "${TEST_ROOT}/metrics.invalid.json" "${TEST_ROOT}/evidence/gcp/results/metrics/metrics.json"
reseal_result_artifact gcp metrics/metrics.json
assert_semantic_rejected negative-rmse 'metrics do not satisfy the frozen smoke policy'
build_provider_evidence gcp

jq '.metrics.calibration.brier = -0.1' "${TEST_ROOT}/evidence/gcp/results/metrics/metrics.json" \
  >"${TEST_ROOT}/metrics.invalid.json"
mv -- "${TEST_ROOT}/metrics.invalid.json" "${TEST_ROOT}/evidence/gcp/results/metrics/metrics.json"
reseal_result_artifact gcp metrics/metrics.json
assert_semantic_rejected negative-brier 'metrics do not satisfy the frozen smoke policy'
build_provider_evidence gcp

jq '.additivity_max_abs_error = -1' "${TEST_ROOT}/evidence/gcp/results/explanations/shap.json" \
  >"${TEST_ROOT}/shap.invalid.json"
mv -- "${TEST_ROOT}/shap.invalid.json" "${TEST_ROOT}/evidence/gcp/results/explanations/shap.json"
reseal_result_artifact gcp explanations/shap.json
assert_semantic_rejected negative-shap-error 'SHAP artifact is invalid'
build_provider_evidence gcp

printf '%s\n' '{"artifact_roots":[]}' \
  >"${TEST_ROOT}/evidence/gcp/results/tracking/mlflow-artifact-tracking.json"
reseal_result_artifact gcp tracking/mlflow-artifact-tracking.json
assert_semantic_rejected incomplete-tracking 'MLflow tracking artifact is invalid'
build_provider_evidence gcp

printf '%s\n' '{"mlflow_sync_status":"synchronized"}' \
  >"${TEST_ROOT}/evidence/gcp/results/run-manifest.json"
reseal_result_artifact gcp run-manifest.json
assert_semantic_rejected incomplete-recovery 'recovery run manifest is invalid'

printf 'Cross-cloud acceptance evidence tests passed. No cloud command ran.\n'
