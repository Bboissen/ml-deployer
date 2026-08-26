# Goal 03: AWS

Status: **Not started**.

## Objective

Implement and accept the common platform contract on one standalone AWS account using a CPU-only EC2 runner.

## Task A: account and state bootstrap

- Reauthenticate with temporary credentials and record a read-only inventory.
- Verify region, Standard/Spot vCPU quota, budget notifications and S3 account protections.
- Confirm the historical claim that no old AWS resources exist.
- Create and accept the protected, versioned S3 state backend with native lockfile support.

## Task B: persistent platform

- Create separate private data and results S3 buckets.
- Create deployer/runtime IAM boundaries without long-lived access keys.
- Create a distinct receipt-publisher control identity that the runner cannot assume.
- Create the minimal network needed by a runner managed through Systems Manager.
- Prove the runner identity has data read and results write access but no state access or infrastructure permissions.

## Task C: disposable runner

- Resolve `smoke`, `balanced` and `highmem` profiles against allowed EC2 types.
- Require IMDSv2 and encrypted storage.
- Pull the exact OCI digest and execute one opaque run spec.
- Enforce scheduled termination plus guest shutdown fallback.
- Prove runner destroy does not touch persistent storage.

## Acceptance

- Backend write, recovery version and bounded lock contention are proven.
- A neutral smoke image produces a conditionally created completion receipt in the reserved control prefix, with publisher metadata independently verified.
- No inbound SSH rule or static cloud credential exists.
- Maximum runtime is visible through an independent AWS control.
- A reviewed destroy removes the runner and leaves state/data/results storage intact.

Every cloud mutation requires its own reviewed saved plan and explicit authorization.
