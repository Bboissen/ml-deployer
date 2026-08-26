# Goal 04: Google Cloud

Status: **In progress — offline scaffold ready; no live GCP or state operation performed**.

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
- Create a distinct receipt-publisher control identity that the runtime account cannot impersonate.
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
- A neutral smoke image produces a conditionally created completion receipt in the reserved control prefix, with publisher metadata independently verified.
- The Compute Engine termination timestamp/action is independently visible.
- The runner and its disposable disk are gone after the accepted lifecycle.

Every cloud mutation requires its own reviewed saved plan and explicit authorization.

## Current offline evidence

- Three flat, provider-owned roots now exist under `infra/gcp/`: local-state
  bootstrap, persistent platform, and one-deployment disposable runner.
- Bootstrap exposes explicit `create` and read-only `adopt_managed`
  preparation. No import block, state move, or historical ownership assertion
  is present.
- Platform storage, IAM conditions, network, registry, and the persistent
  keyless publisher identity are visible GCP resources. IAP/OS Login project
  grants are empty unless an operator explicitly enables IAP and supplies exact
  principals.
- The platform emits a closed hashed provider binding for project, region,
  distinct state/data/results buckets, network, registry, publisher, and fixed
  namespaces. The runner consumes and rehashes the whole binding rather than
  trusting separately supplied identifiers.
- Runner configuration binds the frozen request fields, exact workspace/state
  key, digest-pinned image, immutable run-spec generation, private networking,
  a deployment-unique workload service account and exact IAM, native
  `max_run_duration`/`DELETE`, and a separately authenticated absolute Scheduler
  DELETE for a stopped VM. A fixed five-minute earliest/latest apply window is
  cross-checked against the absolute deadline and requested maximum runtime.
- The startup wrapper preserves guest failures, fails a successful guest when
  evidence publication fails, and conditionally creates a bounded bootstrap log
  plus private local-receipt handoff. The future publisher
  can read only those handoffs and Compute facts, while only it can create
  reserved `control/evidence/` and `control/receipts/.../completion.v1.json`
  objects.
- Provider initialization for validation uses `-backend=false`; no `gcloud`,
  plan, apply, import, state, or remote-backend operation is part of this
  evidence.

Tasks A-C and every acceptance item remain open until their live read-only and
separately authorized mutation evidence is reviewed.
