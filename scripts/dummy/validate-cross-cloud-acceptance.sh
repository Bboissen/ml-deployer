#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIRECTORY}/../.." && pwd -P)"
readonly CANONICAL_ROOT="${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke"

fail() {
  printf 'dummy-cross-cloud-acceptance: ERROR: %s\n' "$1" >&2
  exit 2
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] ||
    fail "missing non-empty regular non-symlink ${label}: ${path}"
}

file_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

require_canonical_copy() {
  local evidence_path="$1"
  local canonical_path="$2"
  local label="$3"
  [[ "$(file_sha256 "$evidence_path")" == "$(file_sha256 "$canonical_path")" ]] ||
    fail "${label} does not match the reviewed common bytes"
}

verify_authorization() {
  local provider="$1"
  local operation="$2"
  local artifact_path="$3"
  local authorization_path="$4"
  local artifact_sha256
  local expected_sentence
  require_file "$artifact_path" "${operation} artifact"
  require_file "$authorization_path" "${operation} authorization"
  artifact_sha256="$(file_sha256 "$artifact_path")"
  expected_sentence="${operation^^} EXACT ARTIFACT sha256:${artifact_sha256} FOR ${provider}"
  jq -e \
    --arg operation "$operation" \
    --arg provider "$provider" \
    --arg artifact_sha256 "$artifact_sha256" \
    --arg authorization "$expected_sentence" '
      keys == ["artifact_sha256", "authorization", "operation", "provider", "schema_version"]
      and .schema_version == "1.0.0"
      and .operation == $operation
      and .provider == $provider
      and .artifact_sha256 == $artifact_sha256
      and .authorization == $authorization
    ' "$authorization_path" >/dev/null ||
    fail "${authorization_path} does not authorize the exact ${operation} artifact"
}

(( $# == 1 )) || fail "usage: $0 ABSOLUTE_EVIDENCE_ROOT"
readonly EVIDENCE_ROOT="$1"
[[ "$EVIDENCE_ROOT" == /* && "$EVIDENCE_ROOT" != /tmp/* ]] ||
  fail "evidence root must be an absolute durable path outside /tmp"
[[ -d "$EVIDENCE_ROOT" && ! -L "$EVIDENCE_ROOT" ]] ||
  fail "evidence root must be a non-symlink directory"

reference_immutable=""
reference_metrics=""
reference_package_versions_sha256=""

for provider in aws gcp azure; do
  provider_root="${EVIDENCE_ROOT}/${provider}"
  [[ -d "$provider_root" && ! -L "$provider_root" ]] || fail "missing ${provider} evidence directory"

  package_lock="${provider_root}/requirements.lock"
  package_matrix="${provider_root}/package-matrix.json"
  source_manifest="${provider_root}/image-source-manifest.json"
  oci_manifest="${provider_root}/oci-manifest.json"
  run_spec="${provider_root}/run-spec.json"
  input="${provider_root}/synthetic-input.parquet"
  output_policy="${provider_root}/expected-output.json"
  result_manifest="${provider_root}/result-manifest.json"
  results_root="${provider_root}/results"
  completion_receipt="${provider_root}/completion-receipt.json"
  publication_bundle="${provider_root}/publication-bundle.json"
  apply_plan="${provider_root}/apply-plan.bin"
  receipt_bundle="${provider_root}/receipt-bundle.json"
  destroy_plan="${provider_root}/destroy-plan.bin"
  publication_record="${provider_root}/receipt-publication.json"
  publication_api_evidence="${provider_root}/receipt-publication-provider-api.json"
  destroy_record="${provider_root}/post-destroy.json"
  destroy_api_evidence="${provider_root}/post-destroy-provider-api.json"

  for required in \
    "$package_lock" "$package_matrix" "$source_manifest" "$oci_manifest" "$run_spec" "$input" \
    "$output_policy" "$result_manifest" "$completion_receipt" \
    "$publication_record" "$publication_api_evidence" "$destroy_record" \
    "$destroy_api_evidence"; do
    require_file "$required" "${provider} evidence"
  done
  [[ -d "$results_root" && ! -L "$results_root" ]] || fail "missing ${provider} results directory"

  require_canonical_copy "$package_lock" "${CANONICAL_ROOT}/requirements.lock" "${provider} package lock"
  require_canonical_copy "$package_matrix" "${CANONICAL_ROOT}/package-matrix.json" "${provider} package matrix"
  require_canonical_copy "$source_manifest" "${CANONICAL_ROOT}/image-source-manifest.json" "${provider} image source manifest"
  require_canonical_copy "$run_spec" "${CANONICAL_ROOT}/run-spec.example.json" "${provider} run spec"
  require_canonical_copy "$input" "${CANONICAL_ROOT}/fixtures/synthetic-input.parquet" "${provider} input"
  require_canonical_copy "$output_policy" "${CANONICAL_ROOT}/expected-output.json" "${provider} output policy"

  package_lock_sha256="$(file_sha256 "$package_lock")"
  package_lock_bytes="$(wc -c <"$package_lock")"
  package_matrix_sha256="$(file_sha256 "$package_matrix")"
  package_matrix_bytes="$(wc -c <"$package_matrix")"
  jq -e \
    --arg lock_sha256 "$package_lock_sha256" \
    --argjson lock_bytes "$package_lock_bytes" \
    --arg matrix_sha256 "$package_matrix_sha256" \
    --argjson matrix_bytes "$package_matrix_bytes" '
      keys == ["files", "schema_version"]
      and .schema_version == "1.0.0"
      and (.files | type == "array" and length >= 1)
      and ([.files[].path] == ([.files[].path] | sort))
      and ([.files[].path] | unique | length) == (.files | length)
      and ([.files[] | select(.path == "requirements.lock")] | length) == 1
      and (.files[] | select(.path == "requirements.lock")
        | .bytes == $lock_bytes and .sha256 == $lock_sha256)
      and ([.files[] | select(.path == "package-matrix.json")] | length) == 1
      and (.files[] | select(.path == "package-matrix.json")
        | .bytes == $matrix_bytes and .sha256 == $matrix_sha256)
    ' "$source_manifest" >/dev/null || fail "${provider} image source manifest does not bind its package contract"

  jq -e '
    .schema_version == "1.0.0"
    and .python.platform == "linux/amd64"
    and (.packages | type == "array" and length == 23)
    and ([.packages[].distribution] | unique | length) == 23
    and (.accepted_claims | index("cpu-only") != null)
    and (.accepted_claims | index("single-node") != null)
    and (.deferred_claims | index("persistent-tracking-service") != null)
  ' "$package_matrix" >/dev/null || fail "${provider} package matrix is invalid"

  jq -e '.schemaVersion == 2' "$oci_manifest" >/dev/null || fail "${provider} OCI manifest is invalid"
  source_manifest_sha256="$(file_sha256 "$source_manifest")"
  oci_manifest_digest="sha256:$(file_sha256 "$oci_manifest")"
  run_spec_sha256="$(file_sha256 "$run_spec")"
  input_sha256="$(file_sha256 "$input")"
  input_bytes="$(wc -c <"$input")"
  output_policy_sha256="$(file_sha256 "$output_policy")"

  jq -e \
    --arg run_spec_sha256 "$run_spec_sha256" \
    --arg input_sha256 "$input_sha256" \
    --argjson input_bytes "$input_bytes" \
    --arg output_policy_sha256 "$output_policy_sha256" '
      .schema_version == "1.0.0"
      and .workload == "tool-complete-dummy"
      and .expected_output_policy_sha256 == $output_policy_sha256
      and .input.sha256 == $input_sha256
      and .input.bytes == $input_bytes
      and .input.object_key == ("fixtures/tool-complete-dummy/" + $input_sha256 + ".parquet")
      and (.input.object_key | contains("latest") | not)
      and .limits == {"optuna_trials": 1, "ray_cpus": 1, "ray_trials": 1, "rows": 64}
      and ($run_spec_sha256 | test("^[0-9a-f]{64}$"))
    ' "$run_spec" >/dev/null || fail "${provider} run spec does not bind the exact input and output policy"

  jq -e '
    .schema_version == "1.0.0"
    and .workload == "tool-complete-dummy"
    and .required_artifacts == [
      "checkpoints/final.json", "data/transformed.parquet", "explanations/shap.json",
      "metrics/metrics.json", "models/linear-model.json", "packages/versions.json",
      "reports/conformance.md", "run-manifest.json", "tracking/mlflow-artifact-tracking.json"
    ]
    and (.exact_artifact_sha256 | keys == ["data/transformed.parquet"])
    and (.exact_artifact_sha256["data/transformed.parquet"] | test("^[0-9a-f]{64}$"))
    and (.exact_logical_results | type == "object")
    and .hpo_policy == {"optuna_trials": 1, "ray_tune_trials": 1}
    and .mlflow_policy.dataset_digest_bound == true
    and .mlflow_policy.explicit_metrics_logged == true
    and .mlflow_policy.nested_runs_enabled == false
    and .mlflow_policy.run_count == 1
    and .mlflow_policy.system_metrics_enabled == false
    and .mlflow_policy.persistent_tracking_service_ready == false
    and .manifest_policy.created_last == true
  ' "$output_policy" >/dev/null || fail "${provider} expected-output policy is invalid"

  bash "${REPOSITORY_ROOT}/scripts/validate-result-manifest.sh" "$result_manifest" >/dev/null ||
    fail "${provider} result manifest is invalid"
  result_manifest_sha256="$(file_sha256 "$result_manifest")"
  [[ "$(jq -er '.run_spec_sha256' "$result_manifest")" == "$run_spec_sha256" ]] ||
    fail "${provider} result manifest is not bound to its run spec"

  while IFS=$'\t' read -r relative_path expected_bytes expected_sha256; do
    artifact_path="${results_root}/${relative_path}"
    require_file "$artifact_path" "${provider} result artifact"
    [[ "$(wc -c <"$artifact_path")" == "$expected_bytes" ]] ||
      fail "${provider} result artifact size differs: ${relative_path}"
    [[ "$(file_sha256 "$artifact_path")" == "$expected_sha256" ]] ||
      fail "${provider} result artifact hash differs: ${relative_path}"
  done < <(jq -r '.artifacts[] | [.path, (.bytes | tostring), .sha256] | @tsv' "$result_manifest")

  [[ "$(jq -c '[.artifacts[].path]' "$result_manifest")" == "$(jq -c '.required_artifacts' "$output_policy")" ]] ||
    fail "${provider} result paths differ from policy"

  metrics_path="${results_root}/metrics/metrics.json"
  packages_path="${results_root}/packages/versions.json"
  shap_path="${results_root}/explanations/shap.json"
  model_path="${results_root}/models/linear-model.json"
  tracking_path="${results_root}/tracking/mlflow-artifact-tracking.json"
  run_manifest_path="${results_root}/run-manifest.json"
  checkpoint_path="${results_root}/checkpoints/final.json"
  transformed_path="${results_root}/data/transformed.parquet"
  report_path="${results_root}/reports/conformance.md"
  for semantic_artifact in \
    "$metrics_path" "$packages_path" "$shap_path" "$model_path" "$tracking_path" \
    "$run_manifest_path" "$checkpoint_path" "$transformed_path" "$report_path"; do
    require_file "$semantic_artifact" "${provider} semantic result artifact"
  done

  jq -e --slurpfile matrix "$package_matrix" '
    . as $versions
    | type == "object"
      and (keys == ($matrix[0].packages | map(.distribution) | sort))
      and all($matrix[0].packages[];
        . as $package | $versions[$package.distribution] == $package.version)
  ' "$packages_path" >/dev/null || fail "${provider} package inventory does not match the frozen matrix"

  jq -e --slurpfile policy "$output_policy" \
    --arg run_spec_sha256 "$run_spec_sha256" \
    --arg input_sha256 "$input_sha256" \
    --argjson input_bytes "$input_bytes" '
      keys == [
        "fixture_bytes", "fixture_sha256", "logical_results", "metrics",
        "run_spec_sha256", "schema_version", "workload"
      ]
      and .schema_version == "1.0.0"
      and .workload == "tool-complete-dummy"
      and .run_spec_sha256 == $run_spec_sha256
      and .fixture_sha256 == $input_sha256
      and .fixture_bytes == $input_bytes
      and .logical_results == $policy[0].exact_logical_results
      and (.metrics | keys == ["calibration", "models", "optuna", "ray_tune", "simulation"])
      and (.metrics.models | keys == [
        "catboost_rmse", "lightgbm_rmse", "linear_rmse", "statsmodels_r_squared", "xgboost_rmse"
      ])
      and ([.metrics.models[]] | all(type == "number"))
      and ([
        .metrics.models.linear_rmse, .metrics.models.xgboost_rmse,
        .metrics.models.catboost_rmse, .metrics.models.lightgbm_rmse
      ] | all(. >= 0))
      and .metrics.models.linear_rmse <= $policy[0].bounded_checks.linear_rmse_max
      and .metrics.models.statsmodels_r_squared >= $policy[0].bounded_checks.statsmodels_r_squared_min
      and .metrics.models.statsmodels_r_squared <= 1
      and .metrics.models.xgboost_rmse <= $policy[0].bounded_checks.xgboost_rmse_max
      and .metrics.models.catboost_rmse <= $policy[0].bounded_checks.catboost_rmse_max
      and .metrics.models.lightgbm_rmse <= $policy[0].bounded_checks.lightgbm_rmse_max
      and (.metrics.calibration.brier | type == "number")
      and .metrics.calibration.brier >= 0
      and .metrics.calibration.brier <= $policy[0].bounded_checks.calibration_brier_max
      and (.metrics.calibration.curve_predicted | type == "array" and length >= 1)
      and (.metrics.calibration.curve_true | type == "array" and length >= 1)
      and .metrics.optuna.trials == $policy[0].hpo_policy.optuna_trials
      and (.metrics.optuna.best_value | type == "number")
      and .metrics.optuna.best_value >= 0
      and .metrics.ray_tune.trials == $policy[0].hpo_policy.ray_tune_trials
      and (.metrics.ray_tune.best_loss | type == "number")
      and .metrics.ray_tune.best_loss >= 0
      and .metrics.simulation.draws == 128
      and ([.metrics.simulation.mean, .metrics.simulation.p05, .metrics.simulation.p95]
        | all(type == "number"))
      and .metrics.simulation.p05 <= .metrics.simulation.mean
      and .metrics.simulation.mean <= .metrics.simulation.p95
    ' "$metrics_path" >/dev/null || fail "${provider} metrics do not satisfy the frozen smoke policy"

  jq -e --slurpfile policy "$output_policy" '
    keys == [
      "additivity_max_abs_error", "background_rows", "explained_output", "explained_rows",
      "explainer", "mean_absolute_attribution", "non_causal"
    ]
    and .explainer == "LinearExplainer"
    and .explained_output == "regression_value"
    and .explained_rows == 4
    and .background_rows == 48
    and .non_causal == true
    and (.mean_absolute_attribution | keys == ["feature_a", "feature_b", "feature_c"])
    and ([.mean_absolute_attribution[]] | all(type == "number"))
    and (.additivity_max_abs_error | type == "number")
    and .additivity_max_abs_error >= 0
    and .additivity_max_abs_error <= $policy[0].bounded_checks.shap_additivity_error_max
  ' "$shap_path" >/dev/null || fail "${provider} SHAP artifact is invalid"

  jq -e '
    keys == ["coefficients", "family", "feature_names", "intercept", "purpose"]
    and .family == "sklearn-linear-regression"
    and .feature_names == ["feature_a", "feature_b", "feature_c"]
    and (.coefficients | type == "array" and length == 3 and all(type == "number"))
    and (.intercept | type == "number")
    and .purpose == "synthetic-shape-only"
  ' "$model_path" >/dev/null || fail "${provider} model artifact is invalid"

  jq -e --arg input_sha256 "$input_sha256" '
    keys == [
      "artifact_roots", "backend", "dataset_digest_bound", "dataset_digest_projection",
      "dataset_full_sha256_parameter_bound", "dataset_source_is_provider_local",
      "explicit_metrics_logged", "nested_runs_enabled", "persistent_service_ready",
      "run_count", "run_finished", "system_metrics_enabled"
    ]
    and .artifact_roots == ["explanations", "models", "recovery"]
    and .backend == "ephemeral-local-sqlite"
    and .dataset_digest_bound == true
    and .dataset_digest_projection == ("sha256:" + $input_sha256[0:29])
    and .dataset_full_sha256_parameter_bound == true
    and .dataset_source_is_provider_local == true
    and .explicit_metrics_logged == true
    and .nested_runs_enabled == false
    and .persistent_service_ready == false
    and .run_count == 1
    and .run_finished == true
    and .system_metrics_enabled == false
  ' "$tracking_path" >/dev/null || fail "${provider} MLflow tracking artifact is invalid"

  jq -e \
    --arg run_spec_sha256 "$run_spec_sha256" \
    --arg input_sha256 "$input_sha256" \
    --arg package_lock_sha256 "$package_lock_sha256" \
    --arg oci_manifest_digest "$oci_manifest_digest" '
      keys == [
        "candidate_generator_version", "checkpoint", "config_hash", "dataset_manifest_hash",
        "dataset_snapshot_id", "environment_lock_hash", "feature_set_hash",
        "fold_definition_hash", "git_commit", "gold_schema_hash", "image_digest",
        "mlflow_run_id", "mlflow_sync_status", "mlflow_tracking_uri_identity",
        "model_family", "region", "run_id", "schema_version", "seed"
      ]
      and .schema_version == "1.0.0"
      and .config_hash == $run_spec_sha256
      and .dataset_manifest_hash == $input_sha256
      and .dataset_snapshot_id == ("synthetic-" + $input_sha256[0:12])
      and .environment_lock_hash == $package_lock_sha256
      and .image_digest == $oci_manifest_digest
      and .mlflow_run_id == .run_id
      and (.mlflow_run_id | test("^[0-9a-f]{32}$"))
      and .mlflow_sync_status == "ephemeral-local-verified"
      and .mlflow_tracking_uri_identity == "ephemeral-local-sqlite"
      and .model_family == "bounded-multi-family-smoke"
      and .checkpoint == "synthetic"
      and .region == "synthetic"
      and ([.feature_set_hash, .fold_definition_hash, .gold_schema_hash]
        | all(test("^[0-9a-f]{64}$")))
  ' "$run_manifest_path" >/dev/null || fail "${provider} recovery run manifest is invalid"

  jq -e --arg run_spec_sha256 "$run_spec_sha256" --arg input_sha256 "$input_sha256" '
    keys == ["completed_stages", "fixture_sha256", "recoverable_training_claim", "run_spec_sha256", "schema_version"]
    and .schema_version == "1.0.0"
    and .run_spec_sha256 == $run_spec_sha256
    and .fixture_sha256 == $input_sha256
    and .recoverable_training_claim == false
    and .completed_stages == [
      "input-validation", "columnar-transforms", "model-families", "bounded-optuna",
      "single-node-ray-tune", "mlflow-polars-dataset-lineage",
      "mlflow-explicit-metrics-and-artifacts", "recovery-run-manifest", "shap",
      "calibration", "simulation"
    ]
  ' "$checkpoint_path" >/dev/null || fail "${provider} checkpoint artifact is invalid"

  expected_transformed_sha256="$(jq -er '.exact_artifact_sha256["data/transformed.parquet"]' "$output_policy")"
  [[ "$(file_sha256 "$transformed_path")" == "$expected_transformed_sha256" ]] ||
    fail "${provider} transformed Parquet does not match the exact output policy"
  grep -Fq 'CPU-only, single-node process shape' "$report_path" ||
    fail "${provider} report is missing the bounded-process claim"
  grep -Fq "$run_spec_sha256" "$report_path" || fail "${provider} report is not bound to the run spec"
  grep -Fq "$input_sha256" "$report_path" || fail "${provider} report is not bound to the input"

  bash "${REPOSITORY_ROOT}/scripts/validate-completion-receipt.sh" "$completion_receipt" >/dev/null ||
    fail "${provider} completion receipt is invalid"
  completion_receipt_sha256="$(file_sha256 "$completion_receipt")"
  jq -e \
    --arg provider "$provider" \
    --arg oci_manifest_digest "$oci_manifest_digest" \
    --arg run_spec_sha256 "$run_spec_sha256" \
    --arg result_manifest_sha256 "$result_manifest_sha256" '
      .provider == $provider
      and .status == "succeeded"
      and .container_exit_code == 0
      and .oci_digest == $oci_manifest_digest
      and .run_spec_sha256 == $run_spec_sha256
      and .result_manifest_sha256 == $result_manifest_sha256
    ' "$completion_receipt" >/dev/null || fail "${provider} completion receipt is not bound to the actual run evidence"

  verify_authorization "$provider" publish "$publication_bundle" "${provider_root}/publication-authorization.json"
  verify_authorization "$provider" apply "$apply_plan" "${provider_root}/apply-authorization.json"
  verify_authorization "$provider" receipt-publish "$receipt_bundle" "${provider_root}/receipt-publish-authorization.json"
  verify_authorization "$provider" destroy "$destroy_plan" "${provider_root}/destroy-authorization.json"

  jq -e \
    --arg provider "$provider" \
    --arg package_lock_sha256 "$package_lock_sha256" \
    --arg package_matrix_sha256 "$package_matrix_sha256" \
    --arg source_manifest_sha256 "$source_manifest_sha256" \
    --arg oci_manifest_digest "$oci_manifest_digest" \
    --arg run_spec_sha256 "$run_spec_sha256" \
    --arg input_sha256 "$input_sha256" \
    --arg output_policy_sha256 "$output_policy_sha256" '
      keys == [
        "expected_output_policy_sha256", "image_source_manifest_sha256", "input_sha256",
        "oci_manifest_digest", "package_lock_sha256", "package_matrix_sha256", "provider",
        "run_spec_sha256", "schema_version"
      ]
      and .schema_version == "1.0.0"
      and .provider == $provider
      and .package_lock_sha256 == $package_lock_sha256
      and .package_matrix_sha256 == $package_matrix_sha256
      and .image_source_manifest_sha256 == $source_manifest_sha256
      and .oci_manifest_digest == $oci_manifest_digest
      and .run_spec_sha256 == $run_spec_sha256
      and .input_sha256 == $input_sha256
      and .expected_output_policy_sha256 == $output_policy_sha256
    ' "$publication_bundle" >/dev/null || fail "${provider} publication bundle is not bound to immutable bytes"

  jq -e \
    --arg provider "$provider" \
    --arg completion_receipt_sha256 "$completion_receipt_sha256" '
      keys == ["completion_receipt_sha256", "provider", "schema_version"]
      and .schema_version == "1.0.0"
      and .provider == $provider
      and .completion_receipt_sha256 == $completion_receipt_sha256
    ' "$receipt_bundle" >/dev/null || fail "${provider} receipt bundle is not bound to the final receipt"

  publication_api_sha256="$(file_sha256 "$publication_api_evidence")"
  jq -e 'type == "object" and length >= 1' "$publication_api_evidence" >/dev/null ||
    fail "${provider} receipt publication provider evidence is not JSON"
  jq -e \
    --arg provider "$provider" \
    --arg receipt_sha256 "$completion_receipt_sha256" \
    --arg api_sha256 "$publication_api_sha256" \
    --slurpfile receipt "$completion_receipt" '
      keys == [
        "deployment_id", "provider", "provider_api_evidence_sha256", "published_at_utc",
        "publisher_identity", "receipt_object_version", "receipt_sha256", "receipt_uri",
        "schema_version"
      ]
      and .schema_version == "1.0.0"
      and .provider == $provider
      and .deployment_id == $receipt[0].deployment_id
      and .receipt_sha256 == $receipt_sha256
      and .receipt_uri == $receipt[0].receipt_uri
      and .publisher_identity == $receipt[0].receipt_publisher_identity
      and .publisher_identity != $receipt[0].workload_identity
      and (.receipt_object_version | type == "string" and test("^[^[:cntrl:][:space:]]{1,512}$"))
      and .provider_api_evidence_sha256 == $api_sha256
      and (try (.published_at_utc | fromdateiso8601) catch false) != false
    ' "$publication_record" >/dev/null || fail "${provider} receipt publication evidence is invalid"

  destroy_api_sha256="$(file_sha256 "$destroy_api_evidence")"
  jq -e 'type == "object" and length >= 1' "$destroy_api_evidence" >/dev/null ||
    fail "${provider} post-destroy provider evidence is not JSON"
  jq -e \
    --arg provider "$provider" \
    --arg api_sha256 "$destroy_api_sha256" \
    --slurpfile receipt "$completion_receipt" '
      keys == [
        "checked_at_utc", "deployment_id", "persistent_storage_retained", "provider",
        "provider_api_evidence_sha256", "runner_absent", "runner_state_absent", "schema_version"
      ]
      and .schema_version == "1.0.0"
      and .provider == $provider
      and .deployment_id == $receipt[0].deployment_id
      and .runner_absent == true
      and .runner_state_absent == true
      and .persistent_storage_retained == true
      and .provider_api_evidence_sha256 == $api_sha256
      and (try (.checked_at_utc | fromdateiso8601) catch false) != false
    ' "$destroy_record" >/dev/null || fail "${provider} post-destroy evidence is invalid"

  immutable="${package_lock_sha256}:${package_matrix_sha256}:${source_manifest_sha256}:${oci_manifest_digest}:${run_spec_sha256}:${input_sha256}:${output_policy_sha256}"
  package_versions_sha256="$(file_sha256 "$packages_path")"
  if [[ -z "$reference_immutable" ]]; then
    reference_immutable="$immutable"
    reference_metrics="$metrics_path"
    reference_package_versions_sha256="$package_versions_sha256"
  else
    [[ "$immutable" == "$reference_immutable" ]] || fail "cross-cloud immutable bytes differ for ${provider}"
    [[ "$package_versions_sha256" == "$reference_package_versions_sha256" ]] ||
      fail "cross-cloud package inventories differ for ${provider}"
    jq -e --slurpfile reference "$reference_metrics" '
      def absolute: if . < 0 then -. else . end;
      def close($left; $right):
        (($left - $right) | absolute)
        <= (1e-9 + 1e-9 * ([$left | absolute, $right | absolute] | max));
      .metrics as $current
      | $reference[0].metrics as $baseline
      | ($current | walk(if type == "number" then 0 else . end))
          == ($baseline | walk(if type == "number" then 0 else . end))
        and all($baseline | paths(type == "number");
          . as $path | close($current | getpath($path); $baseline | getpath($path)))
    ' "$metrics_path" >/dev/null || fail "cross-cloud numerical metrics differ for ${provider}"
  fi
done

IFS=: read -r \
  package_lock_sha256 package_matrix_sha256 source_manifest_sha256 oci_manifest_digest \
  run_spec_sha256 input_sha256 output_policy_sha256 <<<"$reference_immutable"
jq -cn \
  --arg package_lock_sha256 "$package_lock_sha256" \
  --arg package_matrix_sha256 "$package_matrix_sha256" \
  --arg image_source_manifest_sha256 "$source_manifest_sha256" \
  --arg oci_manifest_digest "$oci_manifest_digest" \
  --arg run_spec_sha256 "$run_spec_sha256" \
  --arg input_sha256 "$input_sha256" \
  --arg expected_output_policy_sha256 "$output_policy_sha256" '
  {
    schema_version: "1.0.0",
    status: "accepted",
    providers: ["aws", "gcp", "azure"],
    immutable_contract: {
      package_lock_sha256: $package_lock_sha256,
      package_matrix_sha256: $package_matrix_sha256,
      image_source_manifest_sha256: $image_source_manifest_sha256,
      oci_manifest_digest: $oci_manifest_digest,
      run_spec_sha256: $run_spec_sha256,
      input_sha256: $input_sha256,
      expected_output_policy_sha256: $expected_output_policy_sha256
    },
    cloud_action: false
  }'
