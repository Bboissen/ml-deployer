# Azure account setup

This guide covers subscription and workstation readiness only. It does not authorize creating Azure resources.

## Current status

Azure CLI was not installed during the pivot audit, and the repository has no prior Azure implementation.

## Manual subscription prerequisites

1. Identify the tenant and subscription containing the usable credit.
2. Configure a Cost Management budget and notification recipients.
3. Select one initial region based on total regional vCPU quota, VM-family quota, capacity and Gold data location.
4. Confirm whether the subscription offer restricts Spot VMs, regions or VM families.
5. Confirm permission to create role assignments and managed identities.

Azure budget notifications do not stop resources or consumption.

## Workstation authentication

Install Azure CLI using Microsoft's supported method, then authenticate interactively with MFA:

```bash
az login
az account show
az account set --subscription SUBSCRIPTION_ID
```

Do not put a client secret in `.env`, OpenTofu variables or backend configuration. Local OpenTofu will use Azure CLI authentication; future unattended automation must use workload identity federation rather than a stored secret.

## Read-only quota checks

Check both total regional and per-family quota:

```bash
az vm list-usage --location REGION --output table
```

Quota and physical capacity are separate; a permitted VM family can still be unavailable in a region.

## OpenTofu bootstrap expectations

The Azure bootstrap goal will create a dedicated resource group, storage account and private state container with Blob versioning/soft deletion and Entra ID authentication. The platform goal will create separate generic data and results containers and a managed identity for the runner.

No Gold blob will be uploaded during platform setup.

## Official references

- [Authenticate Terraform to Azure](https://learn.microsoft.com/en-us/azure/developer/terraform/authenticate/authenticate-to-azure)
- [Azure VM vCPU quotas](https://learn.microsoft.com/en-us/azure/virtual-machines/quotas)
- [Managed identities for Azure VMs](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-configure-managed-identities)
- [Authorize Blob access with Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory)
- [Azure VM auto-shutdown](https://learn.microsoft.com/en-us/azure/virtual-machines/auto-shutdown-vm)
- [OpenTofu AzureRM backend](https://opentofu.org/docs/language/settings/backends/azurerm/)
