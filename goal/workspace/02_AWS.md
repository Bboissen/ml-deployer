# AWS ML workspace goals

Status: target accepted; implementation/live acceptance pending. Follow the
[scope](00_SCOPE_AND_CLEANUP.md) and [toolbox contract](01_TOOLBOX_CONTRACT.md).
AWS works independently of GCP, Azure and the homelab.


## Shared foundation inputs and integration boundary

Consume [workspace interface 2.0.0](../../docs/workspace.md),
[the integration ownership and task prompt](05_FOUNDATION_AND_HANDOFF.md) and
[the exact cleanup inventory](06_CLEANUP_INVENTORY.md). Work from the merged
foundation commit in your own provider worktree/branch. Emit request, handoff and
readiness records; use the common validator and toolbox probe. Implement native
storage/authentication/terminal/deadline evidence only in your provider paths.
The shared acceptance source is `shared/workspace/example/`; pin uploaded and
retrieved versions in provider-specific evidence. Local-copy tests are not live
storage acceptance. Do not edit shared files concurrently or require another
provider's implementation. Every live mutation still needs exact authorization.

## A. Reconcile resources and simplify

Milestone-A named targets, read-only preflight and proposed disposition/guard
design are documented in the [AWS workspace quickstart](../../docs/operations/aws-workspace.md).
Review that milestone before implementation B–D or any cloud mutation.

Refresh the expired source login, then inventory the selected account/region,
EC2, disks, addresses, schedules, IAM, buckets, registry and exact state lineage.
Re-establish the historically accepted bootstrap/platform against fresh evidence.
Classify retained data/results buckets, ECR and publisher resources before
changing their ownership. Do not infer current absence from the August teardown.

Retain useful main/PR fixes and replace the AWS dummy adapter with a workspace
lifecycle. Retire mandatory fixture/image/run-spec hashes and ML publisher gates.
Keep existing saved artifacts immutable and propose exact decommission plans for
obsolete cloud resources separately from code cleanup.

Acceptance: a reviewed integration/disposition plan, and no unidentified resource
silently dropped from state or configuration. Stop for review.

## B. Persistent S3 and bounded identity

Keep protected remote-state S3 separate from private persistent workload S3.
Create generic empty storage with versioning/recovery and scoped data/output
prefixes. Publish `s3://` locations and supported boto3/AWS CLI use; no dataset
upload or model behavior is included in bucket creation.

Use a workspace-specific instance role with temporary credentials. Narrow the
existing wildcard SSM parameter reads in both its effective policy and boundary
while preserving required management access. Test unrelated parameters, other
datasets, state and cross-workspace writes are denied. Attach required runtime
and management policies before instance creation; handle propagation boundedly.

Acceptance: native multi-object access works under that role; state/unrelated
resources remain inaccessible; deleting workspace state cannot delete buckets.

## C. EC2 toolbox and terminal

Replace fire-and-exit bootstrap with persistent toolbox readiness. Select a
reviewed supported Linux image, publish tool versions, create a non-root writable
project directory and verify requested instance capacity. Keep IMDSv2 and no
public ingress. Permit Git/package egress through the reviewed network.

Use [Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
for named operators. Include required agent/client readiness and an exact connect
command. Prove an external repo can be cloned at a revision and its dependencies
installed in an isolated environment without a home server or ECR image mirror.
Private Git authentication is an explicit operator workflow, never cloud-init
secrets. Repo-specific packages and scripts remain owned by that repo.

Acceptance: usable session, clone/install/storage handoff and reconnect work.

## D. Safe lifetime and teardown

Close the audit's EC2-before-Scheduler gap: design a provider-side guard active
before or with compute creation. Do not launch under a claim of hard runtime
protection if schedule failure can leave unbounded compute. Order schedule IAM
policies correctly and test failed bootstrap, partial apply and lost sessions.

Document stop versus termination, restart behavior and continuing disk/address
costs. Workspace destroy removes EC2, owned disks/addresses, role/profile/grants
and deadline resources from the exact workspace state. Refresh provider inventory
and reconcile drift; preserve buckets, platform/state and historical evidence.

Acceptance: maximum lifetime is independently enforced; partial failure is
bounded; post-destroy resources are verified absent and storage survives.

## E. Independent end-to-end acceptance

On AWS alone, create/reuse its platform, launch one CPU workspace, connect, clone
an external repo, install its dependencies, read a small authorized dataset and
write/download a test object and pass the deterministic NumPy/pandas example.
No production ML training result is graded. Destroy and launch
a second workspace against the same retained bucket. Prove access denial,
disconnect and expiry cases. Record source/toolbox/plan/identity/resource evidence.

Done when the clean-checkout AWS quickstart reproduces this sequence without
dummy internals or another provider. Offline checks are routine; every live
apply, IAM change, upload and destroy requires its own exact authorization.
