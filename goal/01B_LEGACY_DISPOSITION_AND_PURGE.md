# Goal 01B: Legacy disposition and workspace purge

Status: **Not started**.

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

## Acceptance

- No `artifacts/`, `data/`, old `tofu/`, old `terraform/`, `.gcp-runtime/`, old virtual environment, Python cache or generated ML package metadata remains under the repository root.
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
