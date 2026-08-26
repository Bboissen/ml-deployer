# Parallel provider rights readiness

This document defines the first safe live interaction with AWS, Google Cloud
and Azure. The probes are read-only and may run in parallel after the owner has
confirmed each provider's non-secret account scope. They do not require a
runnable OpenTofu provider root and do not authorize later provider work.

## What the first probe proves

The first probe establishes **visibility readiness**:

- the required CLI is installed;
- a temporary interactive identity is active;
- the selected account, project or subscription is the intended one;
- the selected region is visible;
- billing status, required services and quota information are readable where
  the provider exposes them;
- existing storage, identities, compute, disks, addresses and relevant IAM are
  enumerable;
- the intended deployer can be identified without using a stored secret.

The probe must return the common `doctor` JSON envelope defined in
[`interface.md`](interface.md). Provider results are independent: one provider
may pass while another is blocked.

## What it does not prove

Visibility is not create authority. Listing resources or reading IAM does not
prove that a later create, role assignment, backend lock or VM allocation will
succeed.

Even a provider permission-simulation or test-permissions API can be limited by
conditions, organization policy, service control policy, deny assignments,
quota, regional capacity, subscription offer, billing state or a later
credential change. Therefore the readiness probe never reports `apply_ready`
or `mutation_proven`.

Definitive infrastructure review still requires provider-specific code, a
fresh saved plan, policy validation and explicit authorization for that exact
plan digest. Backend locking and end-to-end runner tests are later bounded
mutations with their own authorization gates.

## Forbidden probe behavior

The first probe must not:

- log in or refresh credentials on the operator's behalf;
- select or change the default account, project, subscription or region;
- enable services or register resource providers;
- create a budget, quota request, bucket, object, state lock, identity, role
  assignment, network, VM, disk or address;
- change IAM, billing, public-access controls or organization policy;
- initialize or apply an OpenTofu root;
- write a test object to prove storage access;
- import, move, refresh or rewrite state;
- imply that historical resources are adopted.

Authentication and CLI installation are manual prerequisites. The probe fails
closed when they are missing.

## Shared result model

Each provider reports these independent sections:

| Section | Meaning |
| --- | --- |
| `tooling` | Required CLI and supported version are present |
| `identity` | Active non-secret principal and intended account scope |
| `visibility` | Inventory, IAM, service and quota queries completed |
| `declared_permissions` | Read-only analysis of permissions needed later |
| `constraints` | Visible policy, quota, billing or regional blockers |
| `historical_inventory` | Existing resources requiring later disposition |

`declared_permissions` has status `unknown` until a provider goal defines an
exact root-specific permission manifest. When supported, later adapters may use
read-only permission simulation or test-permissions APIs against that manifest.
That result remains advisory and does not become apply authorization.

## AWS boundary

Readiness snapshot 2026-08-26: profile `sposhfi-admin` uses temporary AWS CLI
`login` credentials for account `000000000000` in `us-east-1`. No static access
key is created or stored. Because the session expires, every later task must
reauthenticate and recheck the binding before planning.

The AWS probe may perform only read operations equivalent to:

```bash
aws sts get-caller-identity
aws configure get region
aws service-quotas list-service-quotas --service-code ec2 --region REGION
aws s3api list-buckets
aws ec2 describe-instances --region REGION
aws ec2 describe-volumes --region REGION
aws ec2 describe-addresses --region REGION
aws ec2 describe-vpcs --region REGION
aws ec2 describe-subnets --region REGION
```

The later AWS permission manifest covers, by root, S3 backend and object
locking, IAM roles and instance profiles, EC2/network resources, Systems
Manager, scheduling/deadline controls and read-only quota/billing evidence.
It also covers a control-plane receipt-publisher role that the runner cannot
assume and conditional creation in the reserved receipt prefix.
Role-policy simulation can inform the result but cannot account perfectly for
service control policies, permissions boundaries, resource policies and
request-time conditions.

## Google Cloud boundary

Readiness snapshot 2026-08-26: the owner confirmed project
`example-project`, region `us-central1`, zone `us-central1-a`
and the keyless `tofu-deployer` service account. Application Default
Credentials impersonate that account; no service-account key file is used. A
later task must recheck these bindings without changing the active `gcloud`
configuration.

The Google Cloud probe may perform only read operations equivalent to:

```bash
gcloud auth list --filter=status:ACTIVE --format=value(account)
gcloud config get-value project
gcloud auth application-default print-access-token >/dev/null
gcloud projects describe PROJECT --format=json
gcloud beta billing projects describe PROJECT --format=json
gcloud services list --enabled --project PROJECT --format=json
gcloud compute project-info describe --project PROJECT --format=json
gcloud compute regions describe REGION --project PROJECT --format=json
gcloud storage buckets list --project PROJECT --format=json
gcloud iam service-accounts list --project PROJECT --format=json
gcloud compute instances list --project PROJECT --format=json
gcloud compute disks list --project PROJECT --format=json
gcloud compute addresses list --project PROJECT --format=json
gcloud projects get-iam-policy PROJECT --format=json
```

An access token is used only in memory and is never emitted in the readiness
JSON or logs. After the deployer identity is explicitly selected, a short-lived
impersonation-token check may prove that the workstation identity can
impersonate it; it does not adopt that service account or prove create success.

The probe must freshly enumerate and digest the existing buckets and service
accounts. The cleanup receipt recorded four of each and no instances, disks or
reserved addresses, but that point-in-time evidence is not a current inventory.
No existing bucket, service account or IAM binding is altered. Classification
and state-lineage verification belong to Goal 04.

The later GCP permission manifest covers, by root, project/service visibility,
GCS backend and workload storage, service-account administration and act-as,
Compute Engine/network resources, OS Login/IAP when enabled, native runtime
limits and regional quota. IAM test-permissions results remain subject to
organization policy, quota, billing and capacity.
The manifest separately proves the runner cannot impersonate the receipt
publisher and cannot write the reserved receipt prefix.

## Azure boundary

Readiness snapshot 2026-08-26: Azure CLI `2.89.1` is installed and interactive
authentication binds the intended Azure for Students tenant and subscription
to `swedencentral`. The four required resource providers are registered, and
the student spending limit plus annual budget are visible. The probe does not
call `az account set` and no client secret is stored.

The Azure probe may perform only read operations equivalent to:

```bash
az account show --output json
az account list-locations --output json
az provider show --namespace Microsoft.Compute --output json
az provider show --namespace Microsoft.Network --output json
az provider show --namespace Microsoft.Storage --output json
az provider show --namespace Microsoft.ManagedIdentity --output json
az vm list-usage --location REGION --output json
az resource list --subscription SUBSCRIPTION_ID --output json
az storage account list --subscription SUBSCRIPTION_ID --output json
az vm list --subscription SUBSCRIPTION_ID --output json
az disk list --subscription SUBSCRIPTION_ID --output json
az network public-ip list --subscription SUBSCRIPTION_ID --output json
az role assignment list --subscription SUBSCRIPTION_ID --all --output json
```

The later Azure permission manifest covers, by root, resource groups, Blob
backend and workload storage, managed identities and role assignments,
networking, VM/disk resources, Run Command, auto-shutdown and regional/family
quota. Role assignments alone do not prove authority because deny assignments,
Azure Policy, provider registration, quota, offer restrictions and capacity can
still block creation.
It separately defines a control-plane receipt publisher, create-only Blob
conditions and a negative runner-access check for the control prefix.

## Earliest useful test points

1. **Immediately after manual prerequisites:** run all three read-only probes in
   parallel. This proves tooling, authentication, scope and visibility only.
2. **After provider permission manifests exist:** rerun the probes with
   read-only permission simulation or test-permissions checks. This proves the
   declared IAM surface appears available, not that creation will succeed.
3. **After provider code and saved plans are reviewed:** inspect exact plan
   digests and policy summaries. No apply follows without separate explicit
   authorization.
4. **After exact smoke plans are authorized:** perform the first bounded
   mutation and independently verify backend locking, workload identity,
   runtime deadline, trusted conditional receipt creation and runner deletion.

AWS, Google Cloud and Azure may progress through the first two read-only stages
in parallel. Provider implementations and mutations remain isolated behind
their own roots, plans, identities and review receipts.
