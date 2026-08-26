# Architecture

## Design principle

The three providers implement one behavioral contract, not one shared resource graph. AWS, Google Cloud and Azure have different identity, storage, networking and lifecycle semantics, so each provider keeps independent OpenTofu roots.

Common work is limited to:

- input and output names;
- OCI and run-spec validation;
- resource-profile semantics;
- cloud-init behavior where it is truly portable;
- lifecycle commands and acceptance evidence;
- documentation and offline tests.

## Deployment flow

```text
ML repository
  │
  ├── OCI image pinned by sha256 digest
  └── opaque run specification URI
          │
          ▼
provider preflight ──> reviewed OpenTofu plan ──> explicit apply authorization
          │
          ▼
short-lived VM + native identity
  ├── reads provider-local Gold objects
  ├── pulls the exact OCI image
  ├── executes one whole trial at a time
  ├── writes logs, receipts and results to provider-local result storage
  └── stops or is deleted at the provider-side deadline
```

No trial is distributed across providers. Parallelism comes from deploying independent whole trials to different providers.

## Root layout

Each provider will have:

```text
infra/<provider>/
  bootstrap/   # local-state, one-time creation of the remote backend
  platform/    # generic data/results storage, identity and network foundation
  runner/      # disposable compute and maximum-runtime controls
```

The roots are separate state boundaries:

- `bootstrap` is rarely changed and cannot depend on its own remote backend.
- `platform` owns persistent generic infrastructure.
- `runner` owns disposable, billable compute.

Persistent roots must refuse accidental destroy through lifecycle controls, policy checks and operational gates. Disposable compute must be destroyable without targeting persistent storage.

## Provider mapping

| Capability | AWS | Google Cloud | Azure |
| --- | --- | --- | --- |
| Compute | EC2 | Compute Engine | Linux Virtual Machine |
| Runtime identity | IAM role / instance profile | User-managed service account | Managed identity |
| State | Versioned S3 backend with native lockfile | Versioned GCS backend with locking | Versioned Blob backend with native locking |
| Generic data | Private S3 bucket | Private Cloud Storage bucket | Private Blob container |
| Generic results | Separate private S3 bucket | Separate private Cloud Storage bucket | Separate private Blob container |
| Administration | Systems Manager | OS Login and IAP when enabled | Run Command |
| Runtime bound | Scheduled termination plus guest fallback | `max_run_duration` with delete | Auto-shutdown plus explicit OpenTofu destroy |

## Resource profiles

Profiles describe capacity, not provider SKU names:

| Profile | Minimum shape | Intended use |
| --- | --- | --- |
| `smoke` | 2 vCPU, 8 GiB memory | Runtime and access verification |
| `balanced` | 4 vCPU, 16 GiB memory | Normal fixed trials |
| `highmem` | 4 vCPU, 32 GiB memory | Memory-heavy feature matrices |

Every provider preflight must resolve the requested profile to an available regional SKU and fail closed when quota, capacity or subscription policy does not allow it.

## Deliberate non-abstractions

- Provider configuration is never hidden inside a common module.
- IAM policies are not generated from one cross-cloud policy language.
- Provider-specific security and lifecycle resources remain visible.
- The platform does not parse ML run parameters.
- OpenTofu is infrastructure provisioning, not the experiment scheduler.
