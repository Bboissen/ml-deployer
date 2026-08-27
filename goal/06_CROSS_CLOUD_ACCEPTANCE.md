# Goal 06: Cross-cloud acceptance

Status: **Not started**.

## Objective

Prove that the ML repository can select AWS, Google Cloud or Azure without changing the run contract or embedding provider logic in the ML code.

## Acceptance scenario

Use one OCI image digest and byte-identical `oci-ml-smoke` run specification on all three providers. Provider-local repositories, object URIs and immutable object-version identifiers may differ; the run-spec bytes, container manifest digest and numerical workload may not.

For every provider, capture:

- account/project/subscription and region evidence;
- requested and resolved resource profile;
- reviewed plan digest and authorization;
- workload identity;
- provider-side maximum-runtime evidence;
- container exit status;
- result and completion-receipt checksums;
- package-version evidence and deterministic Parquet, summary and result-manifest hashes;
- post-destroy inventory proving disposable compute is gone;
- persistent storage verification.

## Contract checks

- Common commands and variable names are equivalent.
- No provider-specific parameter is required by the ML image.
- Whole trials can run concurrently across providers.
- One provider failure does not change or corrupt another provider's state or results.
- Duplicate deployment identifiers fail closed or write to isolated result prefixes.
- Partial/interrupted output cannot be mistaken for successful completion.
- ECR, Artifact Registry and ACR expose byte-identical OCI manifest content, not merely equal tags.
- The smoke proves NumPy, SciPy, pandas, Polars, PyArrow, DuckDB, scikit-learn, statsmodels and CPU XGBoost inside the cloud runner image.

## Final documentation

- One quickstart from account readiness to destroyed smoke runner per provider.
- A comparison table of genuine provider differences.
- A handoff document for the ML repository.
- A separate, still-unexecuted plan for Gold dataset integration.

## Completion boundary

Cross-cloud acceptance does not include production Gold training. The ML repository owns the later fixed-trial, ablation and model-family runs.
