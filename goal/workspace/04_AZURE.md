# Azure ML workspace goals

Status: target accepted; implementation/live acceptance pending. Follow the
[scope](00_SCOPE_AND_CLEANUP.md) and [toolbox contract](01_TOOLBOX_CONTRACT.md).
Azure works independently of AWS, GCP and the homelab.

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

## A. Account readiness and simplification

Refresh tenant/subscription, region policy, provider registration, CPU quota,
images, resources and role-assignment authority. October inventory returned no
resources; this does not prove deployment permissions or capacity. Verify
temporary operator/deployer authentication without client secrets.

Create a provider-specific workspace adapter instead of completing the synthetic
ML publisher pipeline. Retain useful PR19 contract/type fixes only where they
apply to the new versioned workspace interface. Classify ACR, control container,
publisher identity and private endpoints before any future retirement; keep
infrastructure evidence separate from ML result semantics.

Acceptance: a reviewed source/resource plan and supported launch/access route.
Stop for review before account, IAM or provisioning changes.

## B. Blob storage and managed identity

Keep Entra-authenticated state storage separate from persistent private workload
storage. Implement the common project storage architecture above in the later
Azure task:
`ml_project_name`, the same project/workspace namespaces and `auto/create/existing`
selection. Use one project workload container in its workload account; create the
required empty native storage when unassigned or reuse an explicit reviewed
assignment. Keep public/anonymous object access disabled and require recovery/
versioning. Review storage-network reachability and its cost separately; the
common architecture does not prescribe an unreviewed paid access route. Publish
the native HTTPS Blob location plus
account/container/prefix fields and azure-identity/azure-storage-blob/Azure CLI
usage. Do not require SAS tokens, account keys or an S3 gateway.

Attach a workspace-specific managed identity, expose its non-secret selection
identifier and scope dataset reads/output writes appropriately. Verify storage
network/DNS reachability through the reviewed private network. External data
upload/adoption and broader access are separately reviewed ownership decisions.

Acceptance: native multi-object operations work under managed identity; state,
unrelated containers and other workspace outputs are denied; data survives teardown.

## C. Toolbox VM and actual terminal access

Use the [global RAM-first quota-bounded default](../README.md#execution-rules):
maximize RAM, then vCPUs, within this subscription's remaining regional/family
quotas and the reviewed image/zone constraints. Observe Azure quotas, SKU
restrictions and usage before selecting the exact VM size; do not transplant
AWS's 8-vCPU limit, request quota increases or silently reduce capacity. No Azure
default SKU or native capacity acceptance is established by the AWS C/D task.

Provide a supported, reproducible Linux image/bootstrap with the common toolbox,
a writable non-root project directory and accurate CPU/memory/disk facts. Remove
the assumption that an undocumented prebuilt image already contains the needed
tools. Allow reviewed Git/package egress without a homelab relay or another cloud.

Select and review an authenticated interactive access route and its lifetime/cost,
such as [Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview)
with supported SSH access. Azure Run Command is useful for management checks but
does not by itself satisfy interactive clone-and-work acceptance. Keep operator
permissions exact and avoid internet-wide SSH. If access adds infrastructure,
make its ownership and teardown explicit before provisioning.

Acceptance: a documented connection can clone an external repo, install its
dependencies and use Blob storage; reconnect works without ML publisher setup.

## D. Hard lifetime and billing-state correctness

Replace the assumption that guest shutdown plus a daily HHMM schedule bounds all
failures. Establish an independent provider-side absolute guard active before
or with VM creation, covering failed bootstrap, partial apply and late schedule
creation. Decide and document deallocation versus deletion behavior; a guest
poweroff can leave a billed allocated VM. See [Azure billing states](https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing).

Destroy the workspace VM, disk, NIC, public IP, managed identity/grants and owned
deadline/access resources from its exact state. Verify the resource group is
empty/removed as designed. Retain platform/state/workload storage and record any
remaining paid access/private-network resources. Do not advertise zero ongoing
cost while disks, addresses, endpoints or storage remain.

Acceptance: provider-side lifetime protection survives partial failure; actual
billing-relevant states and post-destroy absence are verified; Blob data remains.

## E. Independent end-to-end acceptance

On Azure alone, accept its bootstrap/platform, launch and connect, clone an
external repo, install dependencies, read multiple small authorized Blob objects
and write/download a test object. Pass the deterministic NumPy/pandas example;
prove denied access, disconnect and expiry.
Destroy and launch a second workspace against retained storage. No production
ML training, trusted ML receipt, ACR mirror or comparison with AWS/GCP is a
prerequisite.

Done when the clean-checkout Azure quickstart works through these stages. Keep
unsupported paths closed before spending. Offline checks and each exact live
apply, role assignment, upload and destroy have distinct acceptance/authorization.
