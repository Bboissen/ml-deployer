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
storage. Create a workload account/container with public access disabled and
appropriate recovery/versioning. Publish the native HTTPS Blob location plus
account/container/prefix fields and azure-identity/azure-storage-blob/Azure CLI
usage. Do not require SAS tokens, account keys or an S3 gateway.

Attach a workspace-specific managed identity, expose its non-secret selection
identifier and scope dataset reads/output writes appropriately. Verify storage
network/DNS reachability through the reviewed private network. External data
upload/adoption and broader access are separately reviewed ownership decisions.

Acceptance: native multi-object operations work under managed identity; state,
unrelated containers and other workspace outputs are denied; data survives teardown.

## C. Toolbox VM and actual terminal access

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
