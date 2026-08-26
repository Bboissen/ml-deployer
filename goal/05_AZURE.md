# Goal 05: Azure

Status: **Not started**.

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
