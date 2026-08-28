# Azure account setup

These steps establish subscription access; they do not authorize resource
creation.

## One-time subscription basics

1. Identify the intended tenant, subscription, and permitted region.
2. Register Microsoft.Compute, Microsoft.Network, Microsoft.Storage,
   Microsoft.ManagedIdentity, and Microsoft.ContainerRegistry as required by
   the roots.
3. Confirm regional and VM-family vCPU quota and role-assignment permission.
4. Inventory existing resource groups, storage, identities, VMs, disks, public
   addresses, and role assignments.

## Workstation

Install Azure CLI, authenticate interactively with MFA, select the intended
subscription explicitly, and verify it:

```bash
az login
az account set --subscription SUBSCRIPTION_ID
az account show --output json
az vm list-usage --location REGION --output table
az resource list --subscription SUBSCRIPTION_ID --output table
```

Put non-secret identifiers in the ignored `.env`, then:

```bash
source scripts/load-cloud-env.sh azure
```

Do not put a storage key, SAS token, client secret, or private SSH key in
`.env`, OpenTofu variables, backend files, plans, or state. Local OpenTofu uses
Azure CLI authentication; automation must use a separately reviewed federated
identity.

## Project identities

- Source operator: Azure CLI user or federated CI identity.
- Deployer: source identity or a later federated deployer with exact resource
  and role-assignment permissions.
- Runtime: deployment-specific managed identity in runner state.
- Publisher: unattached persistent managed identity, invoked outside the VM.

Use Azure Run Command for normal remote administration. The subnet security
group denies inbound traffic; the runner-owned public address supplies outbound
connectivity only and is removed with runner state.

Use the checked-in examples under `infra/azure/*`. The bootstrap root keeps
local state; platform and runner backend files must be populated only from
reviewed bootstrap outputs.
