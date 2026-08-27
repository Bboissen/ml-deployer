# Goal 03: AWS

Status: **In progress — Tasks A and B accepted; Task C local conformance build verified, AWS publication and publisher-policy review pending**.

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

## Account-readiness evidence (2026-08-26)

- AWS CLI temporary `login` credentials bind profile `sposhfi-admin` to account
  `000000000000` in `us-east-1`; no static access key is configured for this
  repository.
- Standard On-Demand and Spot quotas are both 8 vCPUs. The account-level S3
  Block Public Access controls and default EBS encryption are enabled.
- A USD 25 monthly budget and a service anomaly monitor are present.
- The initial live inventory contained no S3 buckets, EC2 instances, EBS
  volumes or Elastic IP addresses. Task A subsequently created exactly one S3
  state-backend bucket. Default networking remains visible but is not adopted
  by this evidence.
- The broad setup user is authenticated. The historical proposed
  `spotify-tofu-deployer` role is absent and is not an accepted neutral
  identity name. Task B still owns the reviewed least-privilege IAM boundary;
  readiness does not authorize creating it.

## Current scaffold and Task A evidence

- The sealed Task A receipt is retained outside the repository at
  `/home/user/evidence/Ray_terraform/aws/goal-03-task-a/backend-acceptance/46b4c94/smoke-01/revision-2-plan-01/task-a-acceptance-receipt.json`
  with SHA-256
  `7eae60b3d390495a63f1930bfdecb8293e0d2daf2ea0e823dc3fd42cc499cc04`.
- The bootstrap, platform and runner roots are separate flat state boundaries
  under `infra/aws/` with root-owned provider configuration.
- OpenTofu is pinned to `1.12.3`; every root pins `hashicorp/aws` `6.61.0` and
  owns a dependency lock file.
- The bootstrap local state remains retained as evidence. The accepted S3 state
  bucket is protected and versioned; platform and runner backend examples use
  native `use_lockfile = true`.
- Offline validation covers protected storage, immutable ECR, no-ingress
  networking, SSM/runtime boundaries, isolated conditional receipt publication,
  IMDSv2, encrypted runner storage and absolute EventBridge Scheduler
  termination.
- The platform emits a closed canonical binding for the account, region,
  storage, network, registry and distinct control identities; the runner binds
  those exact inputs and derives both request and platform hashes locally.
- The reviewed start and derived five-minute latest-apply window prevent an
  early or stale apply from extending the provider deadline beyond the accepted
  maximum runtime.
- The disposable backend acceptance root proved a state write, two retrievable
  state versions and bounded native lock contention. The platform root has now
  been applied from its exact accepted saved plan into the protected backend;
  the runner root has not been applied.
- A fresh read-only review on 2026-08-26 reconfirmed the accepted account and
  region, both 8-vCPU Standard quotas, the cost controls, all state-bucket
  protections, both state versions and released native lock history. It also
  reconfirmed that no Task B or Task C IAM, ECR, Scheduler, EC2 or workload
  storage resource exists.

## Task B saved-plan evidence (2026-08-27)

- The approved binding targets account `000000000000`, region `us-east-1`,
  availability zone `us-east-1a`, resource prefix `demo`, data bucket
  `demo-data-000000000000-us-east-1`, results bucket
  `demo-results-000000000000-us-east-1`, ECR repository `demo/runner`, VPC
  `10.80.0.0/20`, runner subnet `10.80.0.0/24`, and temporary deployer trust
  principal `arn:aws:iam::000000000000:user/sposhfi-admin`.
- The sealed source manifest has SHA-256
  `89a89c5f03e13f0c05d595b6fa5a4677def5875db45be3604b0c7d4f84ee102e`.
- Exactly one saved plan was prepared outside the repository at
  `/home/user/evidence/Ray_terraform/aws/goal-03-task-b/platform/source-89a89c5f03e1/plan-01/platform.tfplan`.
  Its SHA-256 is
  `d51074489e47fdfc04fe9558bea108cb81d703e3067acdd3b8ebccf0f425adb2`.
- The plan contains 27 creates, zero updates, zero replacements and zero
  deletes: 14 persistent S3 resources, six IAM resources, six network
  resources and one ECR repository. It does not create a runner.
- The plan-time review discloses IAM and bucket-policy JSON fields whose values
  remain known only after apply because they consume ARNs created by the same
  saved plan. Their deterministic names and exact configuration references are
  sealed and reviewed; they are not mislabeled as plan-time known.
- Read-only AWS inventories immediately before and after planning match. Only
  the accepted state bucket exists, the platform state and lock keys remain
  empty, and no Task B or Task C resource was created.
- The saved-plan review receipt is retained beside the plan as
  `task-b-plan-review-receipt.json` with SHA-256
  `b97085f55b80c8ba743c769505d9cb3f05f9fdbfa87ac0f49fc3bf747c19a913`.
- Evidence-bound plan and IAM contract tests now enforce the exact create/read
  allowlists and fail closed on deletion, binding drift, ingress, removed state
  denial, weakened receipt deletion and broadened publisher reads.
- Read-only post-apply validators cover the closed platform output,
  S3/ECR/network/IAM inventory, resolved same-plan policies and positive and
  negative IAM simulations. They do not apply infrastructure or write test
  objects. The acceptance procedure is documented in
  `docs/operations/aws-platform-acceptance.md`.

## Task B acceptance evidence (2026-08-27)

- The user authorized the exact saved-plan SHA-256, account and region. The
  authorization is sealed with SHA-256
  `ad41a86939ec61a2317e6db4d895946210f2e2bd50981e5c6a2bbe8f46952487`.
- The exact saved plan completed once with terminal exit `0`: 27 resources
  added, zero changed and zero destroyed. The apply ran from the sealed source
  and external initialized data directory; no Task C resource was present in
  the plan.
- The resulting platform contract SHA-256 is
  `6dda6749f95e1deb449ad2f2bd27dab92d6f29b87ad92621ad41f30c92622131`.
  Platform state version `BuuRrxboRUOfyvvvrLmS0egu7WXUlAFK` is current and no
  native lock remains.
- The live platform inventory and positive/negative IAM simulation matrix both
  passed read-only. Data, results and ECR were empty; Task C roles, instances
  and schedules remained absent.
- Two local validator defects were exposed by the first post-apply attempts:
  jq pipeline precedence and an unsupported IAM simulation context type. Both
  failed attempts are retained, regression-covered and superseded by one
  consolidated live/IAM run with terminal exit `0`.
- A sealed-source convergence plan returned detailed exit `0` and reported no
  changes. No corrective plan was saved or applied.
- The Task B acceptance receipt is retained outside the repository at
  `/home/user/evidence/Ray_terraform/aws/goal-03-task-b/platform/source-89a89c5f03e1/plan-01/apply-01/task-b-acceptance-receipt.json`
  with SHA-256
  `85f11d07476b153f7312c8c4642971164f08c0f4b9ea6dce328b68e08c029a65`.

Tasks A and B are accepted. Task C is unlocked for a separately reviewed
runner binding and saved-plan preparation. Applying any future Task C plan,
publishing OCI or run-spec bytes, destroying resources, pushing, opening a pull
request or merging requires its applicable explicit gate.

## Task C conformance prerequisite

The test-only `oci-ml-smoke` source now defines the intended first workload. It
imports and exercises the pinned CPU statistics/ML stack, reads the exact S3
run-spec version, probes generic data access, and conditionally writes Parquet,
summary and result-manifest objects through the EC2 workload identity. Its
source, lock, base image and run-spec hash require review before building the
publication artifact. A non-running local `linux/amd64` build on the
digest-pinned Python 3.14.7 base verified the fully hashed 48-package install
and all required imports. Its source-manifest SHA-256 is
`686feed4c9eb767b1f87d30f7215030f0d4c147d359e0c9bfb17ea7e5dfa0e68`
and its local-only image digest is
`sha256:04b4c09926e8b610b0014f3c3d35447d9ddbd9dafa0300c55d5f8554196d702f`.
These are preparation evidence, not an authorized registry digest. ECR
publication remains a separate mutation, followed by
a separately reviewed runner saved plan and apply; none is authorized by source
preparation.

The live Task C preflight resolved AWS public SSM parameter
`/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id` to
`ami-0fe74bfcad4fd6bd2`, an available x86-64 Amazon Linux 2023 ECS-optimized
AMI with Docker 25.0.16. `t3.large` is offered in `us-east-1a`; the accepted
ECR repository and the `run-specs/` results prefix remain empty. The runner
bootstrap now starts the preinstalled Docker and SSM services explicitly.

The accepted persistent publisher policy predates the canonical result
manifest and therefore cannot yet attest a successful run. The reviewed source
extension grants it read access only to
`runs/*/results/result-manifest.json`, while continuing to deny arbitrary
result reads. That one-policy platform update requires its own saved plan,
review and exact apply authorization before Task C can produce a trusted final
receipt.
