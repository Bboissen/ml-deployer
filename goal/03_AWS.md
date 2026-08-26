# Goal 03: AWS

Status: **In progress — offline scaffold awaiting review**.

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

## Current offline evidence

- The bootstrap, platform and runner roots are separate flat state boundaries
  under `infra/aws/` with root-owned provider configuration.
- OpenTofu is pinned to `1.12.3`; every root pins `hashicorp/aws` `6.61.0` and
  owns a dependency lock file.
- The bootstrap scaffold has local state only. Platform and runner backend
  examples require the accepted S3 bucket and native `use_lockfile = true`.
- Offline validation covers protected storage, immutable ECR, no-ingress
  networking, SSM/runtime boundaries, isolated conditional receipt publication,
  IMDSv2, encrypted runner storage and an absolute EventBridge Scheduler stop.
- The platform emits a closed canonical binding for the account, region,
  storage, network, registry and distinct control identities; the runner binds
  those exact inputs and derives both request and platform hashes locally.
- The reviewed start and derived five-minute latest-apply window prevent an
  early or stale apply from extending the provider deadline beyond the accepted
  maximum runtime.
- No AWS CLI, backend initialization, cloud plan, apply, import or state command
  has been run for this scaffold.

This evidence does not satisfy Task A inventory or any acceptance mutation.
Backend write/recovery/locking, live IAM, the neutral smoke receipt and reviewed
runner destruction remain blocked on separate plans and explicit authorization.
