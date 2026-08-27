# Tests

Goal 02 contains dependency-free tests for the runner request, completion receipt, deployment index, lifecycle command envelope and portable guest. Provider goals add their own validation, plan-policy, trusted receipt-publication and mocked-provider tests.
The result-manifest tests cover its closed shape plus sorted, unique, bounded and traversal-safe artifact entries.

Routine tests must use OpenTofu validation, plan mode, mocked providers, or dependency-free policy checks. They must never apply real infrastructure by default.

`tests/conformance/test-oci-ml-smoke.sh` validates the test-only image source,
base-image pin, top-level and transitive dependency locks, immutable run-spec
bytes, provider adapters and create-only result semantics. It does not build or
run the image. `make oci-conformance-build` is an explicit, non-default build
that imports the image locally but never runs or pushes it.
`tests/conformance/test-oci-tools.sh` uses a fake registry client to prove
same-manifest verification and rejection of mutable-tag inputs without network
or cloud access.

AWS Task B adds two evidence-bound offline tests:

- `tests/aws/test-platform-plan.sh` checks the exact saved-plan binding,
  resource/action allowlist and protected resource properties, then proves
  rejection of deletion, region-drift and ingress mutations;
- `tests/aws/test-platform-iam-contract.sh` checks the deployer, runtime,
  scheduler, publisher and bucket-policy statement contracts, then proves
  rejection of weakened state/receipt isolation and broadened publisher reads.

`tests/aws/test-platform-live-validator.sh` guarantees that the post-apply
validators remain shell-valid, fail closed without reviewed inputs and contain
no mutating AWS operations. Live acceptance is deliberately separate from unit
tests and is read-only.
