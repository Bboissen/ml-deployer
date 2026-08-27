#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${TEST_DIRECTORY}/../.." && pwd -P)"
readonly FIXTURE_DIRECTORY="${REPOSITORY_ROOT}/shared/conformance/oci-ml-smoke"

fail() {
  printf 'test-oci-ml-smoke: FAIL: %s\n' "$1" >&2
  exit 1
}

for required_file in .dockerignore Dockerfile conformance.py requirements.in requirements.lock run-spec.example.json; do
  [[ -f "${FIXTURE_DIRECTORY}/${required_file}" ]] || fail "missing ${required_file}"
done

readonly EXPECTED_RUN_SPEC_SHA256="57faa9ea92e7fa24c4f49f67ea1ca3a8909e4a0d4541162175efe441450f717e"
actual_run_spec_sha256="$(sha256sum "${FIXTURE_DIRECTORY}/run-spec.example.json" | cut -d' ' -f1)"
[[ "$actual_run_spec_sha256" == "$EXPECTED_RUN_SPEC_SHA256" ]] || fail "run-spec bytes changed without updating the reviewed hash"

jq -e '
  (keys == ["features", "rows", "schema_version", "seed", "workload"])
  and .schema_version == "1.0.0"
  and .workload == "ml-stack-conformance"
  and .rows == 256
  and .features == 6
  and .seed == 20260827
' "${FIXTURE_DIRECTORY}/run-spec.example.json" >/dev/null || fail "run spec violates its closed smoke contract"

readonly EXPECTED_PYTHON_BASE_IMAGE="python:3.14.7-slim-bookworm@sha256:6e9a7d1f48cf0127a5be29b58dba0c7f1b59c118619f011b7a6fca28d00adfd4"
grep -Fxq "FROM ${EXPECTED_PYTHON_BASE_IMAGE}" "${FIXTURE_DIRECTORY}/Dockerfile" ||
  fail "Python base image does not match the reviewed Python 3.14.7 digest"
grep -Eq '^# syntax=docker/dockerfile:1\.7@sha256:[0-9a-f]{64}$' \
  "${FIXTURE_DIRECTORY}/Dockerfile" || fail "Dockerfile frontend is not digest-pinned"
grep -Fq 'python -m pip install --no-cache-dir --require-hashes' \
  "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image install does not enforce lock hashes"
grep -Fq 'USER 10001:10001' "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image does not run as the fixed non-root user"
grep -Fq 'ENTRYPOINT ["python", "/opt/conformance/conformance.py"]' \
  "${FIXTURE_DIRECTORY}/Dockerfile" || fail "image entrypoint is not fixed"
[[ "$(sed -n '1,4p' "${FIXTURE_DIRECTORY}/.dockerignore")" == $'*\n!Dockerfile\n!conformance.py\n!requirements.lock' ]] ||
  fail "Docker build context allowlist changed"

required_packages=(
  azure-identity
  azure-storage-blob
  boto3
  duckdb
  google-cloud-storage
  numpy
  pandas
  polars
  pyarrow
  scikit-learn
  scipy
  statsmodels
  xgboost-cpu
)

for package in "${required_packages[@]}"; do
  grep -Eq "^${package}==[0-9]" "${FIXTURE_DIRECTORY}/requirements.in" || fail "${package} is not exactly pinned in requirements.in"
  grep -Eq "^${package}==[0-9]" "${FIXTURE_DIRECTORY}/requirements.lock" || fail "${package} is absent from the transitive lock"
done

if grep -Ev '^(#.*|$|[a-z0-9][a-z0-9._-]*==[A-Za-z0-9.!+_-]+)$' \
    "${FIXTURE_DIRECTORY}/requirements.in" | grep -q .; then
  fail "requirements.in contains a non-comment, non-exact requirement"
fi

grep -Fq -- '--hash=sha256:' "${FIXTURE_DIRECTORY}/requirements.lock" || fail "transitive lock contains no hashes"
grep -Fq -- '--python-version 3.14' "${FIXTURE_DIRECTORY}/requirements.lock" ||
  fail "transitive lock was not generated for Python 3.14"
if grep -Eq '(^|[[:space:]])(--index-url|--extra-index-url|https?://)' \
    "${FIXTURE_DIRECTORY}/requirements.lock"; then
  fail "transitive lock embeds a package index or direct URL"
fi

for provider_class in S3ObjectStore GcsObjectStore AzureObjectStore; do
  grep -Fq "class ${provider_class}(ObjectStore):" "${FIXTURE_DIRECTORY}/conformance.py" || fail "missing ${provider_class}"
done

for required_probe in \
  'IfNoneMatch="*"' \
  'if_generation_match=0' \
  'overwrite=False' \
  'read_parquet(?)' \
  'pl.read_parquet' \
  'LinearRegression().fit' \
  'sm.OLS' \
  'XGBRegressor('; do
  grep -Fq "$required_probe" "${FIXTURE_DIRECTORY}/conformance.py" || fail "missing conformance probe: ${required_probe}"
done

if rg -n '(AKIA[0-9A-Z]{16}|client_secret|account_key|password[[:space:]]*=)' \
    "${FIXTURE_DIRECTORY}" >/dev/null; then
  fail "conformance fixture appears to contain a credential"
fi

printf 'OCI ML conformance static contract passed. No image was run and no cloud command was executed.\n'
