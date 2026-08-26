# Pivot preservation record

Goal 01B removed the temporary pivot quarantine from the repository workspace on 2026-08-26. No permanent `legacy/`, archive, state, plan, artifact, data, cache, environment or runtime-evidence tree remains inside the repository.

## External evidence archive

The minimum historical recovery evidence is retained outside the repository at:

```text
/home/user/archives/Ray_terraform/legacy-evidence-20260826
```

The archive contains 56 files and 244,258 payload bytes. Repository-relative source paths are preserved below `files/`. `MANIFEST.tsv` records every source path, byte size and SHA-256 checksum; its own SHA-256 is:

```text
71e74906fa57fbfc264fe6b121f76245021ec837bc97b3ccd654a52d52c5928a
```

The archive is owned by `bbsn:bbsn`. Directories are mode `0700` and files are mode `0600`. Its README records the source commit, retention purpose and verification caveat. A bounded scan found no credential values and no ML dataset or result bulk.

Retain this archive until every historical live resource has exactly one reviewed disposition:

- **adopted** into a new provider root with verified state lineage;
- **retained externally** with an owner and explicit non-management boundary; or
- **decommissioned** through a separately reviewed and authorized saved plan.

The archive does not authorize a cloud apply, destroy, import, state move, IAM change or billing mutation.

## Workspace cleanup receipt

Cleanup began from merged baseline `7821802180bca263b6bddd2a3be9e5dd52fd27d1` on branch `chore/legacy-disposition`.

- Exactly 23 reviewed targets were removed after archive verification.
- Their pre-cleanup apparent size was 34,650,826,868 bytes.
- The workspace changed from 12,139 non-Git entries to 41 entries and 55,651 apparent bytes.
- No `artifacts/`, `data/`, old `tofu/`, old `terraform/`, `.gcp-runtime/`, virtual environment, provider cache, Python cache, saved plan, state file, runtime log or generated ML package material remains.
- The external archive passed a second manifest verification after deletion.

Obsolete ML data, generated artifacts, caches, environments and reproducible provider material were permanently removed. Only the bounded 56-file state/evidence set is recoverable from the external archive.

## Read-only live-resource receipt

Immediately before and after local deletion, Google Cloud inventory returned identical canonical JSON digests:

| Inventory | Count | SHA-256 |
| --- | ---: | --- |
| Buckets | 4 | `6b3accecd0fe0761ac27c8f4c2dc3610b662ccba2b5d9b95245fc7eb9d9ba3f3` |
| Service accounts | 4 | `22c10e10781eda260dc77dcf1358e409233950dfa34681d50b6a514475f582f4` |
| Compute instances | 0 | `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945` |
| Persistent disks | 0 | `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945` |
| Reserved addresses | 0 | `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945` |

AWS inventory was unavailable at both boundaries because the `sposhfi-admin` CLI session had expired. DigitalOcean and Azure CLIs were not installed. These are explicit coverage limits, not evidence that resources were removed. The cleanup invoked no cloud mutation command.

Every later adoption or decommission task begins with a fresh read-only inventory. Dropping DigitalOcean from repository scope does not authorize destruction of its historical resources.
