# Deployer audit

This source audit starts at `055454b` (`feat/aws-deployer-release`), the baseline
selected for the audit. Changes are isolated on `refactor/deployer-audit`; the
older dirty checkout, other worktrees and existing deployment evidence remain
owned by their original tasks.

## Scope and disposition

- Review the controller, installation/release path, shared validation, provider
  roots, guest execution, lifecycle safeguards and offline tests.
- Repair confirmed defects and consolidate equivalent code. Keep AWS, Google
  Cloud and Azure implementations separate, and preserve historical interfaces
  while workspace migration remains incomplete.
- Make the existing reviewed AWS deployment the primary launch path. Google
  Cloud and Azure workspace launch remains unsupported until its infrastructure
  and lifetime requirements are implemented and accepted.
- Preserve native state, buckets, identities, plans, authorizations and receipts.
  This audit changes source only; it does not provision, migrate, publish a
  release, upload datasets or decommission cloud resources.
- Tests use mocked providers and temporary task-owned paths. Delete disposable
  test payloads after each run and retain only small logs and cleanup receipts.

## Review areas

Parallel reviews cover controller/recovery, infrastructure/runtime, and
installation/release/testing. Integration covers launch ergonomics, shared code,
documentation and regression checks. Findings and validation results will be
recorded here as fixes land.
