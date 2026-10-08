# Goal 06: Tool-complete dummy image and cross-cloud acceptance

Cloud sizing follows the [global RAM-first quota-bounded default](README.md#execution-rules).

Historical batch/demo plan. The current product target is the
[workspace milestone](README.md). Existing interfaces and immutable evidence
remain preserved until a separately reviewed provider migration.

Status: **Common image/contract/operator milestone ready for review; provider
adapters and live acceptance remain pending**.

This was the terminal goal for the historical batch stage. Deploy one bounded
dummy ML workload through the final process on AWS, Google Cloud, and Azure.
The dummy performs representative work with synthetic data and the real
runtime toolchain, but contains no production model logic, experiment choices,
Spotify-specific transformation, or production Gold dataset.

## Task A: freeze the tool-complete dummy image

Use the ML planning package under
`docs/ml-project/` (untracked, awaiting reviewed export) to freeze an exact package
matrix and hashed dependency lock. Tool-complete means the packages required by
the accepted default workflow, not every speculative future challenger.

The minimum reviewed families are:

- data and columnar execution: NumPy, SciPy, pandas, PyArrow/Parquet, DuckDB,
  and Polars;
- boundary validation and command/test entrypoints: Pydantic, Pandera, Typer,
  and pytest;
- baseline and model ladder: scikit-learn, statsmodels, XGBoost, CatBoost, and
  LightGBM;
- bounded HPO and local orchestration: Optuna and single-node Ray Tune;
- experiment lineage and diagnosis: MLflow experiment tracking and SHAP;
- AWS, GCP, and Azure object-store adapters using temporary workload identity.

The quick dummy uses one ephemeral MLflow run with Polars dataset lineage,
explicit metrics, bounded artifacts, and a redundant recovery
`run-manifest.json`. Optuna and local Ray Tune each execute exactly one trial
and report their results to that run. Nested campaign runs, the Ray MLflow
callback, and MLflow system monitoring are intentionally not part of this
smoke profile. The local SQLite backend and artifact directory are deleted
after their contents are verified. This does not accept or deploy the planned
home tracking server, PostgreSQL backend, proxied object-artifact store, Model
Registry, or any persistent tracking service.

Deferred temporal-model, online-drift, GPU/CUDA, feature-store, and persistent
tracking-service packages are not silently required. Add any of them only when
the ML project selects the tool and the infrastructure claim is separately
reviewed. The current acceptance claim is CPU, single-node, and batch.

Build one `linux/amd64` OCI image from the reviewed source and lock. Mirror its
exact manifest to ECR, Artifact Registry, and ACR without rebuilding it per
provider. Each registry must resolve to the same canonical manifest content.

## Task B: exercise the final process with synthetic data

The dummy workload must remain small and deterministic while exercising the
interfaces the future ML image will use:

1. start as a non-root user and report the locked package inventory;
2. read and checksum an immutable, provider-local run specification;
3. read the same small synthetic Parquet input from generic provider storage;
4. validate it, transform it with DuckDB/Polars/PyArrow, and run minimal smoke
   operations for the accepted model, HPO, tracking, explainability,
   calibration, and simulation tool families;
5. write representative Parquet, metrics, model, tracking, explanation,
   checkpoint, recovery run-manifest, and report artifacts only under the
   deployment output prefix;
6. create the canonical result manifest last and exit with a truthful terminal
   code;
7. leave final receipt publication to the distinct trusted control identity.

The synthetic fixture is infrastructure test data, not a Gold release. The
same fixture bytes, run-spec bytes, random seeds, and logical expected outputs
must be used on all three providers. Provider SDK behavior and object-version
identifiers may differ.

## Task C: provide a fail-closed Make/OpenTofu operator surface

The repository must expose documented Make targets, backed by the existing
provider-specific OpenTofu roots and narrow scripts, for:

- offline repository/image checks, local build, and local dummy execution;
- provider readiness and immutable image/run-spec/input publication review;
- one-provider runner plan, exact saved-plan apply, bounded observation, trusted
  receipt verification, saved destroy plan, exact destroy, and post-destroy
  verification;
- read-only validation of the final AWS/GCP/Azure acceptance receipts.

The minimum discoverable operator surface is below, where `PROVIDER` is
exactly `aws`, `gcp`, or `azure`:

```text
make dummy-image-check
make dummy-image-build
make dummy-image-run-local
make CLOUD=PROVIDER dummy-preflight
make CLOUD=PROVIDER dummy-publication-review
make CLOUD=PROVIDER dummy-publish PUBLICATION_AUTHORIZATION=...
make CLOUD=PROVIDER dummy-plan
make CLOUD=PROVIDER dummy-apply SAVED_PLAN=... APPLY_AUTHORIZATION=...
make CLOUD=PROVIDER dummy-observe
make CLOUD=PROVIDER dummy-receipt-publish RECEIPT_BUNDLE=... RECEIPT_PUBLISH_AUTHORIZATION=...
make CLOUD=PROVIDER dummy-receipt-check
make CLOUD=PROVIDER dummy-destroy-plan
make CLOUD=PROVIDER dummy-destroy SAVED_PLAN=... DESTROY_AUTHORIZATION=...
make CLOUD=PROVIDER dummy-post-destroy-check
make dummy-cross-cloud-acceptance EVIDENCE_ROOT=...
```

Exact authorization values must identify reviewed durable artifacts; they are
not boolean switches or informal confirmation strings. The accepted Goal 02
command-result version 1 remains unchanged and is used only for its existing
`doctor`, `plan`, `observe`, and `destroy` operations. Other lifecycle steps
must emit their documented operation-specific evidence; they must not label a
`publish` or `apply` result as a different command merely to fit version 1.

The common dispatcher is `scripts/dummy/dispatch.sh`. Later provider tasks add
exactly one executable at `scripts/dummy/providers/PROVIDER.sh`; a missing
adapter is an intentional hard failure. Common preflight/publication/plan gates
require `PACKAGE_LOCK_SHA256`, `IMAGE_SOURCE_MANIFEST_SHA256`,
`OCI_MANIFEST_DIGEST`, `RUN_SPEC_SHA256`, and `INPUT_SHA256`. Publication also
requires a durable `PUBLICATION_BUNDLE`, its matching
`PUBLICATION_BUNDLE_SHA256`, and an exact JSON `PUBLICATION_AUTHORIZATION`.
Receipt publication uses the same closed pattern with `RECEIPT_BUNDLE`,
`RECEIPT_BUNDLE_SHA256`, and `RECEIPT_PUBLISH_AUTHORIZATION`. Apply and destroy
require a durable absolute
`SAVED_PLAN`, its matching `SAVED_PLAN_SHA256`, and an exact JSON
`APPLY_AUTHORIZATION` or `DESTROY_AUTHORIZATION`. The authorization sentence is
closed as `OPERATION EXACT ARTIFACT sha256:HASH FOR PROVIDER`.

Targets must require an explicit provider and exact reviewed artifacts. Apply,
publication, receipt publication, and destroy remain separate mutations. No
target may replan during apply, deploy all providers in one mutation, infer an
authorization, or treat a passing preflight as permission to continue.

Each runner root must continue to emit the common deployment, provider, runner,
workload-identity, resource-profile, deadline, data/results/receipt URI,
request-hash, platform-contract-hash, management-hint, and backend-key outputs.

Cross-cloud acceptance reads the actual evidence bytes under
`EVIDENCE_ROOT/{aws,gcp,azure}/`, not a provider-authored acceptance summary.
Each directory must contain the exact package lock, package matrix, image-source
manifest, OCI manifest, run spec, synthetic input, expected-output policy,
canonical result manifest and its listed `results/` artifacts, final completion
receipt,
the publication/receipt/apply/destroy artifacts with their exact authorization
files, provider-authenticated receipt-publication evidence, and post-destroy
verification evidence. The common validator checks every file hash and binding,
the Goal 02 receipt and result-manifest semantics, logical output equivalence,
the exact reviewed package contract and transformed Parquet bytes, bounded
model/HPO/tracking evidence, the distinct publisher identity, provider object
version, runner absence, and persistent-storage retention before comparing
immutable bytes across providers.

## Task D: accept one full lifecycle per provider

Run the same OCI manifest content, byte-identical run-spec bytes, and
byte-identical synthetic input on AWS, Google Cloud, and Azure, one complete
deployment at a time.

For each provider, retain independently verified evidence for:

- account/project/subscription, region, quota, resolved CPU SKU, and current
  ownership/state lineage;
- package-lock, image-source, OCI-manifest, run-spec, and synthetic-input
  hashes;
- publication object versions and saved-plan digests with exact authorization;
- workload identity, backend key, and platform-contract hash;
- provider-side deadline and terminal container outcome;
- result-manifest, log, local receipt, control evidence, final receipt, and
  provider-authenticated publisher/object version;
- runner-only destruction and persistent storage retention.

Acceptance requires every declared package import/smoke to pass, equivalent
logical dummy outputs within predeclared deterministic or numerical checks,
identical receipt semantics, isolated provider state, and verified runner-only
cleanup. It does not require identical resource graphs, SKU names, provider
object-version syntax, or persistent cross-cloud networking.

## Completion boundary

Goal 06 completion means this infrastructure repository can run the final
process shape with a tool-complete dummy image on all three providers. It does
not mean the production ML image exists, production Gold has been integrated,
models have been trained, GPU/distributed capacity has been accepted, or an
online ML service has been deployed. Those are later ML/infrastructure handoff
decisions outside the current goal set.
