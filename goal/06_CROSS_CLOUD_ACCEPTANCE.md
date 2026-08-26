# Goal 06: Cross-cloud acceptance

Status: **Not started**.

## Objective

Prove that the ML repository can select AWS, Google Cloud or Azure without changing the run contract or embedding provider logic in the ML code.

## Acceptance scenario

Use one OCI image digest and one semantically identical smoke run specification on all three providers. Provider-local object URIs may differ; the run-spec content and container digest may not.

For every provider, capture:

- account/project/subscription and region evidence;
- requested and resolved resource profile;
- reviewed plan digest and authorization;
- workload identity;
- provider-side maximum-runtime evidence;
- container exit status;
- result and completion-receipt checksums;
- post-destroy inventory proving disposable compute is gone;
- persistent storage verification.

## Contract checks

- Common commands and variable names are equivalent.
- No provider-specific parameter is required by the ML image.
- Whole trials can run concurrently across providers.
- One provider failure does not change or corrupt another provider's state or results.
- Duplicate deployment identifiers fail closed or write to isolated result prefixes.
- Partial/interrupted output cannot be mistaken for successful completion.

## Final documentation

- One quickstart from account readiness to destroyed smoke runner per provider.
- A comparison table of genuine provider differences.
- A handoff document for the ML repository.
- A separate, still-unexecuted plan for Gold dataset integration.

## Completion boundary

Cross-cloud acceptance does not include production Gold training. The ML repository owns the later fixed-trial, ablation and model-family runs.
