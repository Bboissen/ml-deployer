# Goal 05: Azure

Status: **In progress — account readiness verified; state bootstrap pending**.

## Objective

Implement and accept the common platform contract on the Azure subscription using a CPU-only Linux VM runner.

## Task A: account and state bootstrap

- Install Azure CLI through the supported workstation path.
- Authenticate and record a read-only tenant/subscription, provider, region, quota and budget inventory.
- Create and accept a dedicated state resource group, storage account and container.
- Use Entra ID backend authentication, Blob versioning/soft deletion and native locking.

## Task B: persistent platform

- Create private generic data and results containers separate from state.
- Create a managed identity for the runner.
- Create a distinct receipt-publisher control identity unavailable to the runner.
- Assign the narrowest data-read and results-create/write permissions.
- Create a minimal virtual network and explicit outbound path without inbound SSH exposure.

## Task C: disposable runner

- Resolve common profiles against total regional and VM-family quotas.
- Pull the exact OCI digest and execute one opaque run spec.
- Use Run Command for provider-native administration.
- Configure auto-shutdown plus guest shutdown and explicit OpenTofu destruction.
- Prove runner destruction leaves persistent storage intact.

## Acceptance

- No storage access key, SAS token or client secret is stored in configuration or state inputs.
- A neutral smoke image produces a conditionally created completion receipt in the reserved control prefix, with publisher metadata independently verified.
- Auto-shutdown is independently visible and compute is deallocated at the deadline.
- The reviewed destroy removes disposable VM resources without touching state/data/results storage.

Every cloud mutation requires its own reviewed saved plan and explicit authorization.

## Scaffold evidence (2026-08-26)

The first provider-specific implementation milestone is limited to offline,
plan-ready configuration:

- `infra/azure/bootstrap` retains local state and defines a dedicated state
  resource group, Entra-only versioned Blob account and private state container;
- `infra/azure/platform` defines the persistent workload account with separate
  empty `data`, `results` and `control` containers, a private Blob endpoint,
  Basic ACR with admin/anonymous access disabled, a no-ingress VNet with NAT,
  a reusable no-delete Blob writer role and a distinct unattached receipt
  publisher with evidence-read ABAC;
- `infra/azure/runner` defines one private-NIC Linux VM, encrypted managed disk,
  one unique per-deployment user-assigned runtime identity, exact request and
  platform/backend binding, Azure daily auto-shutdown with a closed five-minute
  apply window and absolute deadline, and the portable guest timeout fallback.
  Runner-state role assignments provide data read, ACR pull, exact immutable
  run-spec read and create/write to only this deployment's exact bootstrap log,
  results prefix and exact non-authoritative local-receipt handoff;
- all three roots pin OpenTofu `1.12.3` and AzureRM `5.0.1` exactly and contain
  an independently generated dependency lock file;
- `tests/azure/test-scaffold.sh` proves the OpenTofu request hash equals the
  normative canonical hash and passes one valid scaffold plus seventeen
  fail-closed policy mutations without contacting Azure.

Offline commands completed successfully:

```text
tofu fmt -recursive infra/azure
tofu -chdir=infra/azure/<bootstrap|platform|runner> init -backend=false
tofu -chdir=infra/azure/<bootstrap|platform|runner> validate
tests/azure/test-scaffold.sh
```

`init -backend=false` installed only the pinned provider package. It did not
initialize Blob state or call Azure APIs.

## Account-readiness evidence (2026-08-26)

- Azure CLI `2.89.1` uses interactive user authentication for tenant
  `91c31672-e62e-4050-9113-4eb29a04a47d` and enabled `Azure for Students`
  subscription `878254b0-ec7f-48bf-ad76-3ef8ff61872b`.
- The accepted location is `swedencentral`. Subscription policy permits only
  Sweden Central, Spain Central, Poland Central, Italy North and UAE North.
- Compute, Network, Storage and Managed Identity providers are registered. The
  student spending limit is on, and annual USD 80 budget
  `demo-azure-student` has actual-cost alerts at 25%, 50%, 75%, 90% and 100%.
- The regional limit is 6 standard vCPUs. Available profile-family limits bind
  `smoke` to `Standard_B2ms`, `balanced` to `Standard_D4s_v4` and `highmem`
  to `Standard_E4ds_v4`. The T4 GPU-family quota remains zero after an
  unsuccessful increase request; GPU support is outside the frozen contract.
- The subscription has no storage account, VM, managed disk, public IP or
  billable resource. One empty pre-existing resource group,
  `rg-demo-ml-se`, remains outside any adoption claim.

Azure CLI installation, authentication and the read-only inventory portion of
Task A are complete. Backend creation, saved plans, applies, role changes,
smoke execution, receipt publication and destruction evidence remain pending
their exact review gates. The first live plan must also prove that subscription
policy and the target storage account accept the version-2 Blob-path ABAC
conditions. None of the Goal 05 acceptance bullets is claimed by readiness.

The common `oci-ml-smoke` fixture is the intended Task C workload after state
and platform acceptance. ACR must expose the exact manifest digest proven in
ECR and Artifact Registry, and the same run-spec bytes must be stored as an
immutable Blob version. Fixture preparation does not authorize any Azure
resource creation, image push, object upload or runner apply.
