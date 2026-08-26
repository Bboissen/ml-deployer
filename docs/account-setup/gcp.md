# Google Cloud account setup

This guide covers project and workstation readiness only. It does not authorize creating or changing Google Cloud resources.

## Existing-resource warning

The pivot audit found existing buckets and service accounts. Do not create replacements or alter their IAM until the GCP adoption decision is reviewed. See [`../preservation.md`](../preservation.md).

## Manual project prerequisites

1. Select the project and confirm its billing account and remaining credit terms.
2. Configure a billing budget and notification channel.
3. Select one initial region based on CPU quota, capacity, Gold data location and credit eligibility.
4. Review inherited IAM convenience roles before accepting bucket access.
5. Confirm whether organization policies restrict service-account creation, external IPs or allowed regions.

Ordinary Google Cloud budget alerts do not cap spending.

## Workstation authentication

Application Default Credentials are the supported local path. Prefer service-account impersonation to service-account key files:

```bash
gcloud auth login
gcloud auth application-default login --impersonate-service-account DEPLOYER_SERVICE_ACCOUNT
gcloud config get-value project
```

The accepted local deployer is the keyless `tofu-deployer` service account in
the selected project. Its exact email remains a canonical ignored `.env` value;
later tasks must validate that binding rather than guess or create another
identity.

## Read-only quota checks

Inspect project and regional CPU quota before selecting a machine type:

```bash
gcloud compute project-info describe
gcloud compute regions describe REGION
```

New projects can also have a global CPU quota. The live project value is authoritative.

## OpenTofu bootstrap expectations

The GCP bootstrap goal will adopt or create a dedicated private, versioned Cloud Storage state bucket with locking. The platform goal will adopt or create separate generic data and results buckets with uniform bucket-level access and public access prevention.

No Gold object will be uploaded during platform setup.

## Official references

- [Authentication for Terraform on Google Cloud](https://docs.cloud.google.com/docs/terraform/authentication)
- [Compute Engine allocation quotas](https://docs.cloud.google.com/compute/resource-usage)
- [Uniform bucket-level access](https://docs.cloud.google.com/storage/docs/using-uniform-bucket-level-access)
- [Cloud Storage IAM](https://docs.cloud.google.com/storage/docs/access-control/using-iam-permissions)
- [Limit VM runtime](https://docs.cloud.google.com/compute/docs/instances/limit-vm-runtime)
- [OpenTofu GCS backend](https://opentofu.org/docs/language/settings/backends/gcs/)
