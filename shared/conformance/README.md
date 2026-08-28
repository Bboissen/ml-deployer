# OCI ML conformance workload

`oci-ml-smoke` is a provider-neutral, CPU-only, single-node acceptance fixture
for the infrastructure contract. It is not production model code, a Gold-data
pipeline, an experiment choice, or a substitute for the future image published
by the ML repository.

The same built image is copied without rebuilding to AWS ECR, Google Artifact
Registry, and Azure Container Registry. Every provider request must bind the
same manifest digest. A successful cloud run proves that the runner can:

- pull the exact private OCI artifact through its temporary workload identity;
- read and checksum an immutable provider-local run specification;
- read and checksum the exact content-addressed 4,991-byte synthetic Parquet
  object from generic provider storage;
- import and exercise the pinned scientific Python stack;
- round-trip Parquet through PyArrow, DuckDB, and Polars;
- fit bounded scikit-learn, statsmodels, CPU XGBoost, CatBoost, and LightGBM
  smoke models;
- execute one Optuna trial and one single-node Ray Tune trial;
- create one ephemeral local MLflow run with Polars dataset lineage, explicit
  metrics, artifacts, and a redundant recovery run manifest;
- calculate bounded SHAP, calibration, and simulation evidence;
- conditionally create result objects and a canonical result manifest; and
- return exit code zero for the provider wrapper's receipt workflow.

The image contains provider SDK adapters only because the accepted version-1
container contract exposes provider-local object URIs and native workload
identity to the container. The numerical workload and run-spec bytes are
provider-neutral.

The ephemeral MLflow SQLite metadata backend and local artifact directory are
verified during the run and then deleted. They validate only a quick
client/artifact process shape. They do not claim nested campaign runs, system
monitoring, the planned persistent tracking server, PostgreSQL backend, proxied
S3-compatible artifact store, Registry, public endpoint, or Kubernetes
deployment is ready.

## Files

- `Dockerfile` pins the Python base image by OCI index digest and installs only
  the fully hashed lock file.
- `.dockerignore` limits the BuildKit context to the Dockerfile, locked wheels
  and entrypoint source.
- `requirements.in` records the reviewed top-level package set.
- `requirements.lock` is the generated transitive lock used by the image.
- `package-matrix.json` freezes every top-level distribution, import, version,
  role, and accepted/deferred readiness claim.
- `conformance.py` is the image entrypoint.
- `fixture-contract.json` and `fixtures/synthetic-input.parquet` freeze the
  exact provider-neutral input bytes, schema, and logical results.
- `expected-output.json` freezes required artifact paths, the deterministic
  transformed-Parquet hash, and bounded checks.
- `run-spec.example.json` is the identical opaque input used by all providers;
  it binds the fixture and expected-output policy hashes.
- `image-source-manifest.json` binds every reviewed image source byte.
- `test_conformance.py` contains fail-closed package/import and negative tests
  that run during the image build.

Use `make dummy-image-check`, `make dummy-image-build`, and
`make dummy-image-run-local` in that order. The local run uses no network and a
provider-shaped filesystem adapter. Runtime evidence is retained beneath the
ignored `.dummy-runtime/` directory.

Building the image or running static tests is not cloud acceptance. Do not push
it, upload the run specification, create a runner, publish a receipt, or destroy
cloud resources without the applicable exact review and authorization gate.
