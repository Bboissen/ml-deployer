# Goal 02: Common contract and tooling

Status: **Accepted**.

Entry gate: Goal 01B is accepted and the repository workspace contains no quarantined legacy artifacts, state roots, caches or environments.

## Objective

Freeze the provider-neutral interface before any new cloud resource implementation.

## Accepted entry decisions

- OCI identity is the immutable manifest digest. Private images are mirrored into ECR, Artifact Registry and ACR without changing that digest; runners pull from their provider-local mirror through native workload identity. The first neutral smoke image may be public and digest-pinned.
- The ML publisher writes identical immutable run-spec bytes to provider-local results storage under `run-specs/<deployment_id>/<sha256>.json`. The request carries the expected SHA-256; the provider binding records the immutable object version and URI. Infrastructure never parses the run-spec content.
- Each runner deployment owns one independent runner state and deterministic backend key. A deployment index and account/region binding prevent duplicate identifiers and orphaned billable resources.
- A versioned atomic completion receipt is the only success authority. It is conditionally created in a reserved control prefix by a provider identity unavailable to the workload, and binds the accepted request, platform contract, backend and provider scope. Partial results, logs, guest shutdown or payload shape without authenticated publication metadata are not success.
- Physical storage names are provider-owned. Persistent resources use the common `create`, `adopt_managed` or `external_reference` mode; incomplete uploads expire after seven days, while completed data, results and receipts have no automatic expiry in the initial contract.
- Initial runners use `standard` capacity and a maximum runtime from 15 through 720 minutes. `interruptible` remains rejected until the ML repository proves checkpoint recovery.
- After Goal 02 acceptance, Goals 03, 04 and 05 proceed as parallel provider workstreams. Their state, provider configuration, IAM, networking and resource mappings remain separate.

## Deliverables

- Machine-readable validation for digest-pinned OCI references and runner inputs.
- Final container environment and common OpenTofu input/output names.
- Resource-profile contract with provider mapping deferred to provider roots.
- Small `doctor`, `plan`, `observe` and `destroy` command interface specifications.
- Provider-neutral cloud-init responsibilities without embedding ML logic.
- Plan-only or mocked tests proving invalid inputs fail closed.

## Acceptance

- Equivalent AWS, GCP and Azure bindings carry the same valid semantic request and are accepted by one validator.
- Mutable tags, secrets, arbitrary shell fragments and unbounded runtimes are rejected.
- No common module hides provider configuration or provider-specific IAM.
- Tests are offline and create no resources.
- No cloud apply is performed.

## Review evidence

- One validator accepts the three provider-local request bindings as the same semantic workload; nine named invalid fixtures plus generated boundary probes fail closed.
- Completion-receipt validation accepts AWS, Google Cloud, Azure and bootstrap-failure cases; seven named replay, authority, profile, deadline and terminal failures are rejected.
- Deployment-index validation derives the exact backend key and binds the canonical request checksum. Lifecycle command validation requires scoped all-pass evidence and rejects unsafe scope or evidence.
- The portable guest tests execute provider-valid AWS, Google Cloud and Azure bindings exactly once, reject unsafe typed input, preserve atomic local receipts and prove GNU timeout kills a signal-resistant child.
- All five Draft 2020-12 schemas are structurally valid; nine committed positive fixtures conform. Cross-field semantic validators remain mandatory by contract.
- `make check`, `make contract-test`, `make fmt-check`, `git diff --check` and `git diff --cached --check` pass offline.
- Three independent provider-focused re-reviews report PASS with no remaining findings.
- There are zero `.tf` or `.tofu` provider files, no state/plan/cache material, and no cloud command or mutation in Goal 02.

## Review gate

The contract is reviewed and frozen before Goal 03 begins. Provider-specific needs may extend implementation details but may not silently change the common interface.

Owner acceptance recorded on 2026-08-26. Provider Goals 03, 04 and 05 may now begin as isolated sibling workstreams from this accepted baseline.
