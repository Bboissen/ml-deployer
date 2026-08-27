# Goal 01B: Legacy disposition and workspace purge

Status: **Accepted on 2026-08-26**.

## Objective

Remove every quarantined legacy artifact, cache, environment and historical root from the repository workspace before new platform implementation begins.

This goal cleans the local workspace. It does not destroy cloud resources.

## Step 1: exact inventory

Produce a bounded inventory containing path, type, byte size and intended disposition for:

- `artifacts/`, `data/` and any model/result directories;
- `.venv/`, Python caches and generated package metadata;
- old `tofu/` and `terraform/` provider roots, caches and state;
- `.gcp-runtime/` plans, ledgers and backend-smoke material;
- obsolete package-manager locks and local environment files.

The inventory must distinguish reproducible material from the minimum evidence needed for historical cloud-resource recovery.

## Step 2: external evidence archive

Before removing state or evidence from the workspace:

- create an archive outside the repository directory;
- include only required state, backups, plans, ledgers and receipts;
- record original relative paths, byte sizes and SHA-256 checksums;
- verify the archived files against the manifest;
- record archive ownership and retention purpose;
- do not include cloud credentials or unrelated ML artifacts.

The exact archive location and target file list require user approval.

## Step 3: reviewed deletion

After archive verification, request explicit approval for the exact workspace targets. Then remove:

- obsolete ML artifacts and local data;
- provider and Python caches/environments;
- old provider roots and workspace state copies;
- GCP runtime/evidence directories after their required files are archived;
- empty legacy directories and obsolete local configuration.

Use recoverable operations where practical. Report what was removed and what remains recoverable from the external archive.

## Live resources

AWS, GCP and DigitalOcean resources are not deleted by this goal. Their time-specific inventory and adopt/retain/decommission decisions continue in the provider goals. Historical state in the external archive supports those decisions without polluting the new repository workspace.

## Execution evidence

Cleanup was executed on 2026-08-26 from branch `chore/legacy-disposition` at merged baseline `7821802180bca263b6bddd2a3be9e5dd52fd27d1`.

- The approved 56-file evidence set was copied to `/home/user/archives/Ray_terraform/legacy-evidence-20260826` before any source was removed.
- The payload is 244,258 bytes. Its `MANIFEST.tsv` has SHA-256 `71e74906fa57fbfc264fe6b121f76245021ec837bc97b3ccd654a52d52c5928a` and verifies every archived byte against its original repository-relative path.
- The archive is owned by `bbsn:bbsn`; directories are mode `0700` and files are mode `0600`.
- The credential scan found zero matching text files and zero matching plan archives after inspecting 37 ZIP members. The archive contains state, saved plans, ledgers and receipts only, not ML data or artifact bulk.
- Exactly 23 reviewed targets were removed. Their pre-cleanup apparent size was 34,650,826,868 bytes.
- The workspace fell from 12,139 non-Git entries to 41 entries and 55,651 apparent bytes. No approved target, provider state/cache, Python cache/environment, plan, runtime log, Parquet file or generated ML package material remains.
- `git status --short --ignored` was empty immediately after cleanup and before this evidence update.
- Matching read-only Google Cloud queries before and after cleanup returned identical canonical JSON digests: four buckets, four service accounts, and zero instances, disks or reserved addresses.
- AWS read-only queries were unavailable before and after cleanup because profile `sposhfi-admin` requires `aws login`. DigitalOcean and Azure CLIs were absent. No cloud write command was run.

The owner accepted this evidence by explicitly authorizing commit, pull request, merge and progression to Goal 02. Goal 02 remained untouched until that authorization.

## Acceptance

- No `artifacts/`, `data/`, old `tofu/`, old `terraform/`, `.gcp-runtime/`, old virtual environment, Python cache or generated ML package metadata remains under the repository root.
- Any later Python or dependency file is limited to the separately reviewed OCI conformance source; it does not revive the removed legacy ML project.
- `git status --short --ignored` contains only current-project tooling material expected by the new repository.
- The external evidence archive passes its SHA-256 manifest verification.
- The archive contains no ML dataset/artifact bulk and no credential material.
- A read-only cloud inventory confirms this local cleanup did not change live resources.
- Goal 02 remains untouched until this acceptance is reviewed.

## Stop conditions

Stop without deleting if:

- any target has an unknown owner or disposition;
- required state/evidence has no verified archive copy;
- the archive would be created inside the repository;
- credentials or secrets are detected;
- a cleanup command resolves outside the approved exact target list.
