# Goal 02: Common contract and tooling

Status: **Not started**.

Entry gate: Goal 01B is accepted and the repository workspace contains no quarantined legacy artifacts, state roots, caches or environments.

## Objective

Freeze the provider-neutral interface before any new cloud resource implementation.

## Decisions required at entry

- Canonical OCI registry and private-image authentication approach.
- Exact run-spec URI and publishing workflow.
- One deployment per runner state versus a map of independent deployments.
- Completion-receipt schema and minimum observability evidence.
- Storage naming, retention and later Gold adoption modes.

## Deliverables

- Machine-readable validation for digest-pinned OCI references and runner inputs.
- Final container environment and common OpenTofu input/output names.
- Resource-profile contract with provider mapping deferred to provider roots.
- Small `doctor`, `plan`, `observe` and `destroy` command interface specifications.
- Provider-neutral cloud-init responsibilities without embedding ML logic.
- Plan-only or mocked tests proving invalid inputs fail closed.

## Acceptance

- The same valid fixture is accepted for AWS, GCP and Azure configuration generation.
- Mutable tags, secrets, arbitrary shell fragments and unbounded runtimes are rejected.
- No common module hides provider configuration or provider-specific IAM.
- Tests are offline and create no resources.
- No cloud apply is performed.

## Review gate

The contract is reviewed and frozen before Goal 03 begins. Provider-specific needs may extend implementation details but may not silently change the common interface.
