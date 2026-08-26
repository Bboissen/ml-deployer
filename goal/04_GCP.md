# Goal 04: Google Cloud

Status: **Not started**.

## Objective

Adopt the useful existing Google Cloud foundation and implement the common platform contract with a CPU-only Compute Engine runner.

## Task A: inventory and state adoption

- Record a new read-only inventory of buckets, service accounts, IAM, APIs, regions and quotas.
- Classify every historical GCP resource as adopt, retain externally or decommission.
- Verify state lineage before moving or rewriting any root.
- Adopt or create the protected, versioned GCS backend and re-prove locking.

## Task B: persistent platform

- Adopt or create separate generic data and results Cloud Storage buckets.
- Enforce uniform bucket-level access and public access prevention.
- Create a single-purpose runtime service account without a key.
- Prove effective IAM, including inherited project bindings, matches the storage contract.

## Task C: disposable runner

- Resolve common profiles against live regional quota and machine availability.
- Use OS Login and IAP only when interactive access is enabled.
- Pull the exact OCI digest and execute one opaque run spec.
- Enforce native maximum runtime with delete termination.
- Prove runner deletion leaves persistent storage intact.

## Acceptance

- No live historical resource is silently replaced or orphaned.
- Backend and workload IAM are tested through the intended identities.
- A neutral smoke image produces a completion receipt in results storage.
- The Compute Engine termination timestamp/action is independently visible.
- The runner and its disposable disk are gone after the accepted lifecycle.

Every cloud mutation requires its own reviewed saved plan and explicit authorization.
