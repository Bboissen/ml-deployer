# Goal 00: Scope and preservation

Status: **Accepted on 2026-08-26**.

## Decisions

- Support AWS, Google Cloud and Azure only.
- Remove DigitalOcean and the old Ray/ML implementation from the active tracked project.
- Keep model code, XGBoost configuration, trials, ablations, years and result analysis in the ML repository.
- Permit one bounded test-only OCI fixture to exercise representative Python, statistics, Parquet, DuckDB and CPU XGBoost capabilities without owning a real model or experiment.
- Accept only an OCI image pinned by digest and an opaque run specification from the ML repository.
- Let this repository create provider-native runner identities and narrowly scoped storage bindings.
- Create generic empty object storage on every provider; integrate the Gold lakehouse later through a separate review.
- Break backward compatibility rather than preserve the old command and configuration surface.

## Preservation boundary

The clean reset may remove tracked legacy code and documentation. It may not delete:

- local experiment data or artifacts;
- OpenTofu/Terraform state or backups;
- saved plans, receipts or authorization ledgers;
- provider caches during the initial reset;
- live cloud resources.

This boundary is temporary. Goal 01B archives the minimum required state/evidence outside the repository and removes all quarantined legacy material from the workspace before implementation resumes.

## Acceptance

- The ownership boundary is recorded in `docs/scope.md`.
- Historical local and live-resource risks are recorded in `docs/preservation.md`.
- The user approved the new branch base, OCI digest contract and repository-managed storage bindings.

## Non-actions

This goal performs no cloud mutation, state migration, adoption or decommission.
