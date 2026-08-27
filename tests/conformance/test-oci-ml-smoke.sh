#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${TEST_DIRECTORY}/../.." && pwd -P)"
readonly FIXTURE_DIRECTORY="${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke"

fail() {
  printf 'test-oci-ml-smoke: FAIL: %s\n' "$1" >&2
  exit 1
}

for required_file in \
  .dockerignore Dockerfile conformance.py expected-output.json fixture-contract.json \
  fixtures/synthetic-input.parquet generate-fixture.py image-source-manifest.json \
  package-matrix.json requirements.in requirements.lock run-spec.example.json \
  test_conformance.py; do
  [[ -f "${FIXTURE_DIRECTORY}/${required_file}" ]] || fail "missing ${required_file}"
done

readonly EXPECTED_RUN_SPEC_SHA256="0bb4de28f818b1c8155a038367d2bd364f190ce43c98a55f5ffaba42881082f5"
readonly EXPECTED_INPUT_SHA256="45bba45b836be32abfd4a4ccc4e487d96340a752bca16692510847147acd9b12"
readonly EXPECTED_INPUT_BYTES="4991"
readonly EXPECTED_POLICY_SHA256="faf89998eeb0867eb9cb3034f14d97f865b5f2992ee2f1554bb0b8a9685b14e5"

actual_run_spec_sha256="$(sha256sum "${FIXTURE_DIRECTORY}/run-spec.example.json" | cut -d' ' -f1)"
[[ "$actual_run_spec_sha256" == "$EXPECTED_RUN_SPEC_SHA256" ]] ||
  fail "run-spec bytes changed without updating the reviewed hash"
[[ "$(sha256sum "${FIXTURE_DIRECTORY}/fixtures/synthetic-input.parquet" | cut -d' ' -f1)" == "$EXPECTED_INPUT_SHA256" ]] ||
  fail "synthetic fixture bytes changed"
[[ "$(wc -c <"${FIXTURE_DIRECTORY}/fixtures/synthetic-input.parquet")" == "$EXPECTED_INPUT_BYTES" ]] ||
  fail "synthetic fixture size changed"
[[ "$(sha256sum "${FIXTURE_DIRECTORY}/expected-output.json" | cut -d' ' -f1)" == "$EXPECTED_POLICY_SHA256" ]] ||
  fail "expected-output policy bytes changed"

jq -e \
  --arg input_sha256 "$EXPECTED_INPUT_SHA256" \
  --argjson input_bytes "$EXPECTED_INPUT_BYTES" \
  --arg policy_sha256 "$EXPECTED_POLICY_SHA256" '
  keys == ["expected_output_policy_sha256", "input", "limits", "schema_version", "seed", "workload"]
  and .schema_version == "1.0.0"
  and .workload == "tool-complete-dummy"
  and .seed == 20260827
  and .limits == {"optuna_trials": 1, "ray_cpus": 1, "ray_trials": 1, "rows": 64}
  and .input.sha256 == $input_sha256
  and .input.bytes == $input_bytes
  and .input.object_key == ("fixtures/tool-complete-dummy/" + $input_sha256 + ".parquet")
  and .expected_output_policy_sha256 == $policy_sha256
' "${FIXTURE_DIRECTORY}/run-spec.example.json" >/dev/null || fail "run spec violates its closed contract"

jq -e \
  --arg input_sha256 "$EXPECTED_INPUT_SHA256" \
  --argjson input_bytes "$EXPECTED_INPUT_BYTES" '
  .schema_version == "1.0.0"
  and .fixture_kind == "synthetic-infrastructure-test-data"
  and .sha256 == $input_sha256
  and .bytes == $input_bytes
  and .object_key == ("fixtures/tool-complete-dummy/" + $input_sha256 + ".parquet")
  and .logical_results.row_count == 64
  and (.schema | length) == 7
' "${FIXTURE_DIRECTORY}/fixture-contract.json" >/dev/null || fail "fixture contract is invalid"

readonly EXPECTED_PYTHON_BASE_IMAGE="python:3.12.12-bookworm@sha256:c0abd0758831ad99b7a29e0c1a875da9c4abb9a2e3f21e2eeb585dbcadfb6cd0"
grep -Fxq "FROM ${EXPECTED_PYTHON_BASE_IMAGE}" "${FIXTURE_DIRECTORY}/Dockerfile" ||
  fail "Python base image does not match the reviewed Python 3.12.12 digest"
grep -Eq '^# syntax=docker/dockerfile:1\.7@sha256:[0-9a-f]{64}$' \
  "${FIXTURE_DIRECTORY}/Dockerfile" || fail "Dockerfile frontend is not digest-pinned"
grep -Fq 'python -m pip install --no-cache-dir --only-binary=:all: --require-hashes' \
  "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image install does not require hashes and wheels"
grep -Fq 'python -m pip check' "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image does not run pip check"
grep -Fq 'conformance.py validate-install' "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image does not validate imports"
grep -Fq 'python -m pytest' "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image does not run fail-closed tests"
grep -Fq 'USER 10001:10001' "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image does not run as non-root"
grep -Fq 'ENTRYPOINT ["python", "/opt/conformance/conformance.py", "run"]' \
  "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image entrypoint is not fixed"

jq -e '
  .schema_version == "1.0.0"
  and .python.version == "3.12.12"
  and .python.platform == "linux/amd64"
  and (.packages | length) == 23
  and ([.packages[].distribution] | unique | length) == 23
  and ([.packages[].version] | all(test("^[0-9]+\\.[0-9]+")))
  and (.accepted_claims | index("cpu-only") != null)
  and (.accepted_claims | index("single-node") != null)
  and (.deferred_claims | index("gpu-or-cuda") != null)
  and (.deferred_claims | index("persistent-tracking-service") != null)
' "${FIXTURE_DIRECTORY}/package-matrix.json" >/dev/null || fail "package matrix is invalid"

while IFS=$'\t' read -r distribution version; do
  requirement="$distribution"
  [[ "$distribution" == ray ]] && requirement='ray[tune]'
  grep -Fxq "${requirement}==${version}" "${FIXTURE_DIRECTORY}/requirements.in" ||
    fail "${distribution} does not match package-matrix.json in requirements.in"
  grep -Eq "^${distribution}==${version}([[:space:]\\]|$)" "${FIXTURE_DIRECTORY}/requirements.lock" ||
    fail "${distribution} does not match package-matrix.json in requirements.lock"
done < <(jq -r '.packages[] | [.distribution, .version] | @tsv' "${FIXTURE_DIRECTORY}/package-matrix.json")

if grep -Ev '^(#.*|$|[a-z0-9][a-z0-9._-]*(\[[a-z0-9_-]+\])?==[A-Za-z0-9.!+_-]+)$' \
    "${FIXTURE_DIRECTORY}/requirements.in" | grep -q .; then
  fail "requirements.in contains a non-comment, non-exact requirement"
fi
grep -Fq -- '--hash=sha256:' "${FIXTURE_DIRECTORY}/requirements.lock" || fail "lock contains no hashes"
if grep -Eq '(^|[[:space:]])(--index-url|--extra-index-url|https?://)' \
    "${FIXTURE_DIRECTORY}/requirements.lock"; then
  fail "transitive lock embeds a package index or direct URL"
fi
awk '
  /^[a-zA-Z0-9][a-zA-Z0-9._-]*==/ { if (seen && !hashed) exit 1; seen=1; hashed=0 }
  /--hash=sha256:/ { if (seen) hashed=1 }
  END { if (seen && !hashed) exit 1 }
' "${FIXTURE_DIRECTORY}/requirements.lock" || fail "a locked distribution has no wheel hash"

for provider_class in S3ObjectStore GcsObjectStore AzureObjectStore; do
  grep -Fq "class ${provider_class}(ObjectStore):" "${FIXTURE_DIRECTORY}/conformance.py" ||
    fail "missing ${provider_class}"
done

for required_probe in \
  'IfNoneMatch="*"' 'if_generation_match=0' 'overwrite=False' \
  'read_parquet(?)' 'pl.scan_parquet' 'parquet.read_table' \
  'LinearRegression().fit' 'sm.OLS' 'XGBRegressor(' 'CatBoostRegressor(' 'LGBMRegressor(' \
  'optuna.create_study' 'tune.Tuner(' 'mlflow.data.from_polars(' \
  'shap.LinearExplainer' 'calibration_curve(' 'scipy.stats.norm.rvs(' \
  'Artifact("run-manifest.json"' 'RESULT_MANIFEST_PATH'; do
  grep -Fq "$required_probe" "${FIXTURE_DIRECTORY}/conformance.py" ||
    fail "missing conformance probe: ${required_probe}"
done

if grep -Eq 'MLflowLoggerCallback|log_system_metrics' "${FIXTURE_DIRECTORY}/conformance.py"; then
  fail "quick dummy unexpectedly enables nested Ray/MLflow runs or system metrics"
fi

"${REPOSITORY_ROOT}/scripts/oci/verify-image-source-manifest.sh" >/dev/null ||
  fail "image source manifest did not verify"

if rg -n '(AKIA[0-9A-Z]{16}|client_secret|account_key|password[[:space:]]*=)' \
    "${FIXTURE_DIRECTORY}" >/dev/null; then
  fail "conformance fixture appears to contain a credential"
fi

printf 'Tool-complete OCI conformance static contract passed. No image or cloud command ran.\n'
