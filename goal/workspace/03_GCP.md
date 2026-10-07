# Google Cloud ML workspace goals

Status: target accepted; implementation/live acceptance pending. Follow the
[scope](00_SCOPE_AND_CLEANUP.md) and [toolbox contract](01_TOOLBOX_CONTRACT.md).
GCP works independently of AWS, Azure and the homelab.


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

## A. Reconcile existing state and leftovers

Refresh project/region/zone, APIs, quota, images, IAM, storage and compute inventory.
The October audit found no VMs/disks/reserved addresses, but initial and r4 dummy
deployments retained two deletion jobs, four identities and two stale managed
states. Prepare separately reviewed runner-only reconciliation; preserve empty
r2/r3/default states and the persistent platform. Recheck before any mutation.

Classify old artifacts/bronze/silver buckets, data-publisher/training-runtime
identities, default network and legacy state as adopt, retain or decommission.
Old bucket contents were inaccessible in the audit; do not assume emptiness.
Retain useful PR18/19 fixes but replace fixed synthetic paths, output grading,
mandatory Artifact Registry mirroring and the ML publisher lifecycle.

Acceptance: each existing resource has a verified owner/state and disposition;
an exact cleanup plan precedes any destroy. Stop for review.

## B. Persistent GCS and keyless access

Keep protected state GCS separate from generic private workload GCS. Implement
the common project storage architecture above in the later GCP task:
`ml_project_name`, the same project/workspace namespaces and `auto/create/existing`
selection. Create one empty project workload bucket when unassigned; reuse an
explicit assignment with reviewed ownership. Preserve historical bucket addresses
and objects. Require uniform access, public-access prevention and versioning/recovery.
Publish native `gs://` locations and google-cloud-storage/gcloud usage, including
GCS object generations. Do not present GCS as an S3-compatible endpoint.

Use a workspace-specific keyless service account and scoped bucket/prefix grants.
Remove `fixtures/tool-complete-dummy/<hash>.parquet` from generic runner/startup
requirements. Support arbitrary reviewed project dataset paths and multiple
objects. Verify inherited project/folder grants do not override intended limits.

Acceptance: authorized native reads/writes work, state/unrelated storage and other
workspace outputs are denied, and workspace teardown retains workload storage.

## C. Interactive Compute Engine toolbox

Use a supported Linux image that can provide writable project environments and
the agreed tools; review whether the existing container-oriented COS bootstrap
should be replaced for this workflow. Preserve useful temporary-credential and
bootstrap filesystem fixes. Verify actual machine CPU/memory/disk facts.

Enable [IAP SSH](https://docs.cloud.google.com/compute/docs/connect/ssh-using-iap)
and OS Login for exact reviewed operators. Scope the necessary firewall/IAM
rules; do not open internet-wide SSH or require a home tunnel. Document the
connect command and Git/package egress. Clone an independent repo at a revision,
install its lock in an isolated environment, and use its native GCS handoff.

Acceptance: named-operator connection/reconnection and clone/install/storage work;
toolbox readiness does not run the old conformance workload or shut down on exit.

## D. Native deadline and full reconciliation

Retain and verify a creation-time native VM maximum duration with an appropriate
termination action. Preserve an independent guard as needed; a failed Scheduler
creation or startup must not remove the native cap. Handle session disconnect
without extending the absolute lifetime. Test partial apply and stale state.

Destroy workspace VM, owned disk/address, workload/deadline service accounts,
grants/custom roles and jobs from that workspace state. Verify authoritative
resource absence and reconcile provider-triggered deletion in state. Keep GCS,
platform and evidence; do not equate VM disappearance with complete cleanup.

Acceptance: expiry remains bounded during failures, all workspace-owned resources
are absent after teardown, and bucket data is retained.

## E. Independent end-to-end acceptance

On GCP alone, launch and connect, clone an external repo, install dependencies,
read multiple small authorized GCS objects and write/download a test object.
Pass the deterministic NumPy/pandas example. No production training or
cross-provider image/output comparison is required. Exercise
denied access, disconnect and native expiry. Destroy and repeat with the same
retained bucket. Publish a clean-checkout quickstart and infrastructure evidence.

Done without AWS/Azure credentials, registry copies or homelab services. Offline
checks stay non-mutating; live IAM, publication, apply and destroy remain separate
exact authorization gates.
