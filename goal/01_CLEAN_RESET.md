# Goal 01: Clean reset

Status: **Accepted on 2026-08-26**.

## Objective

Create a minimal tracked baseline that describes only the new multi-cloud infrastructure project and cannot be mistaken for a runnable or accepted provider implementation.

## Deliverables

- Remove tracked ML, Ray, DigitalOcean, old AWS/GCP, prompt, report and goal artifacts.
- Rewrite `README.md`, `AGENTS.md`, `.gitignore`, `Makefile`, `.env.example` and tool version configuration.
- Create the new goal pack and current architecture, scope, storage, contract and safety documentation.
- Preserve all ignored historical material and live resources.
- Mark ignored historical material as temporary quarantine pending Goal 01B, not as part of the new workspace.
- Add an offline repository check that cannot contact a cloud provider.

## Acceptance checks

- `make check` passes.
- `make fmt-check` reports honestly that provider code does not yet exist.
- No tracked Python package, ML configuration, DigitalOcean code or old OpenTofu root remains.
- The Git diff contains only the approved clean reset.
- Local state/evidence paths retain their pre-reset files and approximate sizes.
- No cloud command with mutation semantics was run.
- Goal 01B exists as a mandatory gate before common-contract or provider implementation.

## Review gate

Stop after static validation and present the complete deletion/addition summary before committing.

## Rollback

The branch is based on `origin/main`. Until commit, all tracked deletions are recoverable from Git. Ignored quarantined material is outside the diff and is removed only by the separately reviewed Goal 01B target list.
