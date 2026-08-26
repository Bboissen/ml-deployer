# AWS persistent-platform acceptance

This runbook accepts Goal 03 Task B only. It does not authorize applying the
platform, uploading an image or run specification, creating a runner, or
starting Task C.

## Inputs

Keep all mutable execution material and evidence outside the repository. The
acceptance run binds these reviewed artifacts:

- the immutable platform saved plan and its SHA-256;
- `tofu show -json` for that exact plan;
- the Task B saved-plan review receipt;
- the sealed platform source manifest, backend configuration and variable file;
- the reviewed temporary-login AWS profile.

The plan, review receipt and every checksum must pass before an apply decision:

```bash
make aws-platform-plan-test \
  PLAN_JSON=/absolute/evidence/path/platform.tfplan.json \
  REVIEW_RECEIPT=/absolute/evidence/path/task-b-plan-review-receipt.json

sha256sum -c /absolute/evidence/path/SHA256SUMS
```

Any failed checksum, changed platform source, changed backend, changed binding,
unexpected resource action or new plan invalidates the apply gate. Stop and
prepare a new review; do not replan or apply implicitly.

## Exact apply gate

Applying requires an explicit authorization naming the exact saved-plan
SHA-256, AWS account and region. Run only the saved plan from its sealed source
and initialized external data directory. Do not apply from the mutable
repository tree and do not substitute a newly generated plan.

Capture the complete apply output, exit code, start/end timestamps, caller
identity, saved-plan SHA-256 and resulting state version. A nonzero exit is a
terminal partial-failure state: preserve all evidence and live resources, then
stop for review. Do not retry, import, modify state or clean up automatically.

## Read-only post-apply checks

After a successful apply, capture `tofu output -json` outside the repository and
run:

```bash
make aws-platform-live-check \
  REVIEW_RECEIPT=/absolute/evidence/path/task-b-plan-review-receipt.json \
  PLATFORM_OUTPUTS=/absolute/evidence/path/platform-outputs.json \
  AWS_PROFILE=reviewed-temporary-profile
```

The live check performs only AWS `get`, `list`, `describe`, STS identity and IAM
simulation calls. It writes no test objects. It verifies:

- the closed platform contract and independently recomputed canonical hash;
- protected, versioned, encrypted and initially empty data/results buckets;
- TLS-only and conditional receipt-control bucket policies;
- an immutable, encrypted, scan-on-push and initially empty ECR repository;
- the exact VPC, subnet, route, internet gateway and no-ingress security group;
- deployer and publisher trust, inline policies and provider tags;
- runtime and scheduler permissions boundaries after all same-plan ARNs resolve;
- positive and negative IAM simulations for state, runner roles, EC2 launch,
  runtime data/results access, receipt isolation and tagged termination;
- a current platform state version, no current native lock, and no Task C role,
  instance or schedule.

Run a separate convergence plan from the sealed source with the same backend
and variables:

```bash
tofu plan -lock=false -detailed-exitcode
```

Exit `0` is required. Exit `2` means the platform is not converged; exit `1` is
an error. Preserve the output and stop on either nonzero result. Do not save or
apply a corrective plan without another review gate.

## Acceptance receipt

Task B becomes accepted only when a sealed receipt records:

- `status: TASK_B_ACCEPTED`;
- exact saved-plan, source-manifest and authorization hashes;
- apply exit `0` and terminal timestamps;
- resulting platform state version and released-lock evidence;
- platform output and canonical-contract hashes;
- zero-change convergence result;
- successful live and IAM-simulation checks;
- confirmation that data/results/ECR remain empty and Task C remains absent;
- retained paths and SHA-256 values for every supporting artifact.

Stop after the Task B receipt is reviewed. Starting Task C, publishing OCI or
run-spec bytes, creating a runner, or destroying anything requires its own
reviewed scope and authorization.
