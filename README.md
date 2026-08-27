# Multi-cloud ML infrastructure

This repository provisions disposable, single-node ML runners on AWS, Google Cloud, and Azure with OpenTofu.

The project is infrastructure-only. Model code, training logic, experiment definitions, feature families, years, ablations, and result analysis belong to the separate ML repository.

## Status

Goal 02 of the clean-slate pivot is accepted. The legacy Ray, DigitalOcean, and embedded ML implementation has been removed from both the tracked project surface and the local workspace. The bounded historical recovery evidence is archived outside the repository. AWS Tasks A and B are accepted and applied; no AWS runner exists. Google Cloud and Azure have offline scaffolds and read-only readiness evidence but no accepted platform apply. This branch prepares the common conformance artifact and does not authorize or perform any cloud mutation.

The implementation sequence and acceptance gates are defined in [`goal/README.md`](goal/README.md).

## Contract

The ML repository will provide:

- an OCI image reference pinned by `sha256` digest;
- an opaque run specification URI;
- a deployment identifier;
- a requested resource profile and maximum runtime.

This repository will provide:

- provider account and quota preflight checks;
- separate protected state storage;
- generic empty data and results object storage;
- a provider-native workload identity;
- a distinct provider control identity for create-only completion receipts;
- one or more bounded-lifetime VM runners;
- equivalent deployment outputs and lifecycle commands on all three clouds.

See [`docs/contract.md`](docs/contract.md) and [`docs/architecture.md`](docs/architecture.md).

The repository also contains one bounded, test-only
[`OCI ML conformance workload`](shared/conformance/README.md). It exercises the
accepted runtime and representative scientific Python libraries but is not
model or training code. Its gated cross-cloud workflow is documented in
[`docs/operations/oci-conformance.md`](docs/operations/oci-conformance.md).

## Supported platforms

| Platform | Planned compute | Workload identity | Object storage |
| --- | --- | --- | --- |
| AWS | EC2 | IAM role and instance profile | S3 |
| Google Cloud | Compute Engine | User-managed service account | Cloud Storage |
| Azure | Linux Virtual Machine | Managed identity | Blob Storage |

DigitalOcean is not supported.

## Repository layout

```text
docs/       Scope, architecture, contract, setup and operations
goal/       Gated implementation goals and acceptance evidence
infra/      Provider-specific OpenTofu roots, added by later goals
shared/     Provider-neutral contracts and bootstrapping templates
scripts/    Small validation and lifecycle entrypoints
tests/      Offline and plan-only infrastructure tests
```

## Safety

OpenTofu implementation and cloud application are separate gates. A passing validation or plan does not authorize an apply. Goal 01B removed the temporary quarantine and preserved only the reviewed historical recovery evidence in a verified archive outside the repository; see [`docs/preservation.md`](docs/preservation.md). Common-contract work now proceeds through Goal 02; provider implementation remains gated on its separate review.
