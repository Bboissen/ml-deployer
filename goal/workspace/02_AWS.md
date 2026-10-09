# AWS ML workspace goals

Status: C/D source design approved and source implementation delivered for review; native acceptance E remains pending. Follow the
[scope](00_SCOPE_AND_CLEANUP.md) and [toolbox contract](01_TOOLBOX_CONTRACT.md).
AWS works independently of GCP, Azure and the homelab.

Use the [single-configuration AWS workflow](../../docs/operations/aws-workspace.md).
The persistent foundation is deployed and retained after compute teardown.
The UTC handoff serialization fix and configuration refactor are source changes;
terminal, clone and S3 result acceptance remain pending.

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

## Common project storage architecture

Architecture decision: the implementation goal in this task remains **AWS only**.
GCP and Azure consume the same target architecture in their later provider tasks;
updating these goals does not authorize either provider's implementation or any
cloud mutation. Keep provider implementations and native authentication separate.

The deployment input is `ml_project_name`, distinct from the cloud account/project
identifier, infrastructure ownership prefix and external repository dependencies.
Derive a stable, provider-safe `project_slug` from that name and use an explicit
workspace suffix to derive the workspace ID. For example, `fraud-detection` and
workspace `dev-01` identify `fraud-detection-dev-01`. Reject invalid names and
ambiguous/colliding assignments; do not silently reinterpret an existing project.
Do not invent a deployed ML project name from historical infrastructure ownership.

For example, the proposed provider deployment inputs are:

```hcl
ml_project_name = "fraud-detection"
workspace_name  = "dev-01"
storage_mode    = "auto"
```

These inputs derive workspace ID `fraud-detection-dev-01`, data prefix
`projects/fraud-detection/data/` and output prefix
`projects/fraud-detection/workspaces/fraud-detection-dev-01/output/`. Native
resource names retain a readable project component plus a deterministic scope
suffix to satisfy each provider's global-name and length constraints. This is a
configuration example and future behavior, not an existing deployment command
or evidence that storage/compute has been created.

Use **one persistent native workload storage unit per ML project per provider**:
an S3 bucket, a GCS bucket, or an Azure Blob container in its workload storage
account. Keep state in a separate bucket/account. Under the workload storage unit,
use the same namespace on every provider:

- Dataset reads: `projects/<project_slug>/data/`.
- Workspace outputs: `projects/<project_slug>/workspaces/<workspace_id>/output/`.

A workspace may read its reviewed dataset prefix and upload/list/retrieve current
and exact-version objects within its own output prefix, including scoped multipart
operations where supported. Grant no unspecified object/version deletion. Preserve
objects, native version identifiers and storage when a workspace is torn down.
Independent identities enforce these boundaries; a name/prefix alone is not IAM.

Expose `storage_mode = auto | create | existing` in provider deployment
configuration, with `auto` as the intended normal mode:

- `auto`: reuse the project's explicit assignment (including managed storage
  already in its persistent state); otherwise include new empty storage in the
  authorized deployment plan.
- `create`: provision new platform-managed storage initially and reuse that same
  storage/state on subsequent deployments. Never create a new bucket per runner.
- `existing`: require an exact reviewed native storage assignment; verify its
  provider/account/region, private access, versioning/recovery, separate state
  storage and permitted prefixes before use.

An assignment records the ML project, native resource identifiers, account/region,
ownership (`platform-managed` or `external`) and state/source binding. Permission
errors, name collisions, missing assigned storage and unknown ownership fail
closed; they never trigger fallback creation or inferred adoption. Externally
owned storage is referenced without automatic import, state transfer, bucket-policy
replacement or content changes. Switching a managed assignment to an external
reference or renaming/removing it requires a separately reviewed migration; a flag
must not orphan/destroy the old resource.

Creation belongs to the persistent platform root and its reviewed state owner,
separate from state-bootstrap and the disposable runner. Keep all historical
addresses, lineages, objects, plans and evidence. Existing AWS/GCP data/results
buckets do not become empty project storage by relabelling them. New storage uses
provider-safe names derived from the project and a deterministic account/region
suffix; it is private, versioned/recoverable, protected from ordinary destruction
and initially empty. No Gold data upload or ML execution is implied.

Resolve native data/output/state URIs before validating and hashing workspace
interface **2.0.0**. Project name, creation mode and ownership are provider
configuration, not new fields silently added to that closed shared interface.
Emit truthful requested/observed storage metadata; no ready machine handoff is
fabricated. Later deployment still requires reviewed effective identity, exact
backend/source/state binding and authorization for the exact saved plan. Compute
remains closed until toolbox/access and provider lifetime safeguards are accepted.

One storage unit is the small-project default because it keeps ownership and
configuration simple. Bucket count alone is not a meaningful spending cap:
stored bytes, retained versions, requests, transfers and optional networking or
replication features drive costs. Provider-specific cost/access choices remain
explicit at the deployment review. See [AWS storage pricing](https://aws.amazon.com/s3/pricing/),
[GCP storage pricing](https://cloud.google.com/storage/pricing) and
[Azure Blob pricing](https://azure.microsoft.com/en-us/pricing/details/storage/blobs/).

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

Source milestone: project storage preparation, additive protected platform storage,
workspace role/profile and prefix policies are implemented for offline review.
See the [B quickstart and review limits](../../docs/operations/aws-workspace.md).
Live deployment, S3 transfers and effective-access acceptance remain pending.
No C/D readiness or compute launch is enabled.

Keep protected remote-state S3 separate from private persistent workload S3.
Implement the common project storage architecture above: `ml_project_name`,
project-derived namespaces and `auto/create/existing` selection. Create one empty
project workload bucket when unassigned; reuse an explicitly assigned bucket with
reviewed ownership. Preserve historical data/results buckets at their existing
addresses. Require versioning/recovery and scoped data/output prefixes. Publish
`s3://` locations and supported boto3/AWS CLI use; no dataset
upload or model behavior is included in bucket creation.

Use a workspace-specific instance role with temporary credentials. Narrow the
existing wildcard SSM parameter reads in both its effective policy and boundary
while preserving required management access. Test unrelated parameters, other
datasets, state and cross-workspace writes are denied. Attach required runtime
and management policies before instance creation; handle propagation boundedly.

Acceptance: native multi-object access works under that role; state/unrelated
resources remain inaccessible; deleting workspace state cannot delete buckets.

## C. EC2 toolbox and terminal

Source implementation: see the [C/D runbook](../../docs/operations/aws-workspace-cd.md). Offline checks do not establish native access or readiness.

Use the [global RAM-first quota-bounded default](../README.md#execution-rules).
For `aws-personal` / `000000000000` / `us-east-1`, refreshed AWS CLI metadata shows
standard on-demand quota 8 vCPUs, no active usage, and zero X/High Memory/GPU quota.
The C/D source default is `r8i.2xlarge`: 8 vCPUs and 64 GiB RAM, offered in
`us-east-1a` and compatible with the reviewed ENA-enabled x86_64 AMI. Readiness
reports usable RAM after OS overhead. A quota does not guarantee launch capacity
or rights; reread it before the exact native plan and never increase it implicitly.
Record regional EC2/disk/network/guard costs independently of quota.

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

Source implementation provides a persistent watchdog, a deadline armed during
preparation, a separate lease-bound launch role and two reviewed teardown stages.
Native timing/failure acceptance remains in E.

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
