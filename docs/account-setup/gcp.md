# Google Cloud account setup

These steps establish project access; they do not authorize resource creation
or adoption of existing resources.

## One-time project basics

1. Select the intended project and region.
2. Confirm billing is enabled and inspect organization policies for allowed
   regions, external addresses, service accounts, and IAM conditions.
3. Inventory existing buckets, service accounts, IAM, instances, disks, and
   addresses before choosing `create` or `adopt_managed`.
4. Confirm that Compute Engine, Cloud Storage, IAM, Artifact Registry, and
   Cloud Scheduler services are enabled before their first plan.

## Workstation

Use Application Default Credentials and keyless service-account impersonation:

```bash
gcloud auth login
gcloud auth application-default login \
  --impersonate-service-account DEPLOYER_SERVICE_ACCOUNT
gcloud config get-value project
gcloud compute regions describe REGION --project PROJECT
gcloud compute instances list --project PROJECT
gcloud storage buckets list --project PROJECT
```

Put non-secret identifiers in the ignored `.env`, then:

```bash
source scripts/load-cloud-env.sh gcp
```

## Project identities

- Source operator: authenticated human or workload identity.
- Deployer: keyless service account impersonated by the source operator.
- Runtime: deployment-unique service account created in runner state.
- Publisher: persistent keyless service account; never attach or allow the
  runtime identity to impersonate it.
- Deadline: runner-owned service account limited to deleting its exact VM.

Interactive access stays disabled by default. If required, set the platform's
IAP flag and exact operator principals; use OS Login through IAP. The runner's
ephemeral outbound address is not an SSH authorization.

Use the checked-in examples under `infra/gcp/*`. Existing resources require a
fresh inventory and state-lineage decision before import or IAM change.
