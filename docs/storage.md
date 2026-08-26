# Generic storage contract

## Resource separation

Each provider creates three distinct persistent storage concerns:

1. **State storage** contains only OpenTofu state and lock/version history.
2. **Data storage** is initially empty and later receives or references the Gold lakehouse, manifest and ERD.
3. **Results storage** receives run specifications when applicable, logs, receipts and ML outputs.

State storage must never be reused for dataset or result objects. Data and results are separate resources so that read and write permissions remain understandable across all three clouds.

## Provider mapping

| Concern | AWS | Google Cloud | Azure |
| --- | --- | --- | --- |
| State | Dedicated S3 bucket | Dedicated Cloud Storage bucket | Dedicated storage account/container |
| Data | Private S3 bucket | Private Cloud Storage bucket | Private Blob container |
| Results | Private S3 bucket | Private Cloud Storage bucket | Private Blob container |

Names are generated from a short project name plus provider-owned uniqueness material. Callers may supply a compliant suffix, but may not supply arbitrary public-access settings.

## Baseline controls

All storage must have:

- public access disabled;
- provider-managed encryption at rest at minimum;
- TLS-only access where the provider exposes that control;
- versioning or soft-delete recovery suitable for the storage type;
- lifecycle rules for abandoned result uploads and non-current versions;
- provider/account/region and ownership tags or labels;
- no anonymous, wildcard or cross-account access by default.

## Identities

The platform root will create separate identities or role scopes for:

- the OpenTofu deployer;
- the runtime runner;
- a provider control-plane receipt publisher whose credentials are never exposed to the runner;
- the future ML/data publisher, when the Gold integration is designed.

The runner receives:

- read and list access to the data location;
- read access to its run specification;
- create/write access to its own results location;
- an explicit denial or absence of write access to the reserved `control/receipts/` namespace;
- no infrastructure-management permission;
- no state-storage access;
- no data-object deletion permission.

Where a provider cannot express identical create-only semantics with a built-in role, its provider implementation must document and test the narrowest custom policy rather than silently broadening the common contract.

## Gold integration gate

No dataset object is created, uploaded, copied or referenced during the generic-storage goal. When the Gold lakehouse is ready, a separate review will choose one of:

- publishing into the provider-created data storage;
- adopting an existing provider-local bucket/container;
- granting the runtime identity read access to an externally managed location.

That review must define manifest validation, freshness, ownership, object immutability, region alignment and teardown behavior. Destroying infrastructure must never delete an externally owned Gold dataset.

## Persistent-resource modes

Every state, data or results resource uses exactly one reviewed mode:

- `create`: the provider platform root creates and owns a new empty resource;
- `adopt_managed`: an existing resource is accepted only after ownership, live controls, object inventory and state lineage are verified;
- `external_reference`: the resource stays outside this repository's state and exposes only a reviewed identifier and access boundary.

Changing a resource from one mode to another is an adoption or decommission task, not an ordinary variable edit. `force_destroy` or an equivalent destructive setting is forbidden on persistent storage.

## Immutable run-spec and result layout

The ML publisher places identical run-spec bytes in provider-local results storage using:

```text
run-specs/<deployment_id>/<run_spec_sha256>.json
```

The provider binding records the native object version or generation. The runner verifies the expected SHA-256 before starting the container and receives read-only access to that exact object.

Each deployment writes below an isolated prefix:

```text
runs/<deployment_id>/logs/
runs/<deployment_id>/results/
```

The final receipt is outside every workload-writable prefix:

```text
control/receipts/<deployment_id>/completion.v1.json
```

Only the provider control-plane receipt publisher may write that namespace. Before the final receipt it conditionally creates immutable content-addressed control evidence under `control/evidence/<deployment_id>/<sha256>.json`. It then uses a provider-native conditional create for the final payload. The provider returns the final object version or generation only after that create, so observation records it as authenticated external evidence rather than rewriting it into the payload. An existing final object is never overwritten, and the workload identity must not be able to assume or obtain the publisher identity. Provider observation verifies the publisher identity and create-only object metadata before accepting the receipt payload.

Only that verified atomic completion receipt establishes terminal success. The initial contract applies no automatic expiry to completed data, results or receipts. Incomplete multipart/block uploads and explicitly unaccepted temporary uploads expire after seven days. Provider goals may add longer reviewed recovery/version-retention periods but may not silently shorten this boundary.

## Physical naming

Logical purpose and ownership labels are shared, but providers render globally unique physical names within their own constraints. A common module does not generate S3, Cloud Storage and Azure Storage resources. Provider mappings must expose the resulting non-secret URIs through the common output contract.
