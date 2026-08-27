# OCI ML conformance workload

`oci-ml-smoke` is a provider-neutral acceptance fixture for the infrastructure
contract. It is not model code, a training pipeline, or a substitute for the
future image published by the ML repository.

The same built image is copied without rebuilding to AWS ECR, Google Artifact
Registry, and Azure Container Registry. Every provider request must bind the
same manifest digest. A successful cloud run proves that the runner can:

- pull the exact private OCI artifact through its temporary workload identity;
- read and checksum an immutable provider-local run specification;
- read the empty generic data location;
- import and exercise the pinned scientific Python stack;
- round-trip Parquet through PyArrow, DuckDB, and Polars;
- fit deterministic scikit-learn, statsmodels, and CPU XGBoost models;
- conditionally create result objects and a canonical result manifest; and
- return exit code zero for the provider wrapper's receipt workflow.

The image contains provider SDK adapters only because the accepted version-1
container contract exposes provider-local object URIs and native workload
identity to the container. The numerical workload and run-spec bytes are
provider-neutral.

## Files

- `Dockerfile` pins the Python base image by OCI index digest and installs only
  the fully hashed lock file.
- `.dockerignore` limits the BuildKit context to the Dockerfile, locked wheels
  and entrypoint source.
- `requirements.in` records the reviewed top-level package set.
- `requirements.lock` is the generated transitive lock used by the image.
- `conformance.py` is the image entrypoint.
- `run-spec.example.json` is the identical opaque input used by all providers.

Building the image or running static tests is not cloud acceptance. Do not push
it, upload the run specification, create a runner, publish a receipt, or destroy
cloud resources without the applicable exact review and authorization gate.
