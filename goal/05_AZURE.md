# Goal 05: Azure

Status: **In progress — offline scaffold ready; no Azure mutation performed**.

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
initialize Blob state or call Azure APIs. Azure CLI installation, interactive
authentication, subscription/tenant/region confirmation, quota and policy
inventory, backend creation, saved plans, applies, role changes, smoke execution,
receipt publication and destruction evidence are all still pending their exact
review gates. The first live plan must also prove that subscription policy and
the target storage account accept the version-2 Blob-path ABAC conditions. None
of the Goal 05 acceptance bullets is claimed by this scaffold.
