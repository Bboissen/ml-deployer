# Scope and ownership

## Purpose

This repository creates equivalent, disposable ML execution environments on AWS, Google Cloud, and Azure. It is intentionally unaware of the scientific meaning of a run.

## Ownership boundary

| Concern | Infrastructure repository | ML repository |
| --- | --- | --- |
| Cloud account readiness, quota and billing checks | Owns | Consumes evidence |
| OpenTofu state and provider resources | Owns | Does not modify |
| Generic data and results storage | Owns resources and access policy | Owns object content and layout |
| VM image, network and workload identity | Owns | Consumes |
| OCI training image | Validates digest and launches | Builds, tests and publishes |
| Run specification | Treats as opaque URI | Defines and validates |
| Gold manifest, ERD and dataset semantics | Does not interpret | Owns |
| Trial allocation across clouds | Exposes capacity and deployment interface | Decides |
| Training, checkpoints and result analysis | Does not implement | Owns |

## In scope

- AWS, Google Cloud and Azure account setup documentation.
- Provider-specific OpenTofu state bootstrap.
- Generic empty data and results object storage.
- Provider-native identities and least-privilege storage access.
- Single-node CPU runners with bounded lifetimes.
- Equivalent inputs, outputs, operations and offline tests across providers.
- Optional interruptible capacity after checkpoint recovery is proven by the ML repository.

## Out of scope

- Model or feature code, including XGBoost configuration.
- Run, year, family or ablation scheduling logic.
- Data transformation or Gold lakehouse construction.
- Cross-cloud distributed clusters or networking.
- Ray cluster lifecycle.
- DigitalOcean.
- A web dashboard or experiment tracking service.
- Cloud application without exact plan review and authorization.

## Compatibility policy

The pivot intentionally breaks compatibility with the previous repository. Old command names, directory layouts, configuration formats and state roots are not part of the new API.
