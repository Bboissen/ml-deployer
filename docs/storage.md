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
- the future ML/data publisher, when the Gold integration is designed.

The runner receives:

- read and list access to the data location;
- read access to its run specification;
- create/write access to its own results location;
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
