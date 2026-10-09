# Goal 04: Google Cloud

Cloud sizing follows the [global RAM-first quota-bounded default](README.md#execution-rules).

Historical batch/demo plan. The current product target is the
[workspace milestone](README.md). Existing interfaces and immutable evidence
remain preserved until a separately reviewed provider migration.

Status: **Offline implementation complete; live ownership and acceptance pending**.

## Task A: ownership, services, and identities

- Refresh project, region, quota, service, IAM, bucket, identity, compute, disk,
  and address inventory with `gcloud`.
- Classify every existing resource as `create`, `adopt_managed`, retained
  externally, or separately decommissioned; verify state lineage before import.
- Verify keyless source-to-deployer impersonation.
- Verify Artifact Registry and Cloud Scheduler services/service-agent readiness.
- Define how the unattached publisher identity is invoked outside the runner.

## Task B: bootstrap and persistent platform

- Prepare and separately accept the state backend.
- Plan the data/results buckets, Artifact Registry, no-ingress network,
  publisher identity, and IAM conditions.
- Confirm the platform plan contains no Cloud NAT/Router and no runner compute.
- Prove effective inherited IAM does not broaden runtime or publisher rights.

## Task C: disposable runner

- Mirror the exact OCI manifest and upload byte-identical run-spec bytes.
- Plan one VM with a deployment-specific runtime identity, ephemeral outbound
  address, native maximum duration, and independent Scheduler deletion.
- Apply once, observe, invoke the trusted publisher, validate the receipt, and
  destroy runner state.
- Prove VM, disk, runtime/deadline identities, grants, job, and address are gone
  while state, buckets, registry, evidence, and receipt remain.

IAP/OS Login remains disabled unless exact interactive principals are reviewed.
Every cloud mutation requires an exact saved-plan or object-operation gate.
