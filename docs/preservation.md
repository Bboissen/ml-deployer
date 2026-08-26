# Temporary pivot quarantine

This register prevents the tracked clean reset from destroying evidence before it can be classified. The quarantine is temporary and is not part of the target repository or workspace.

No new provider implementation begins until Goal 01B removes the quarantined material from this repository directory.

## Snapshot

Audit date: 2026-08-26.

The following local paths are ignored by Git and were temporarily retained during the tracked reset:

- `.gcp-runtime/`: GCP authorization ledgers, saved plans and backend-smoke evidence;
- `artifacts/`: approximately 27 GiB of historical ML outputs and authorization receipts;
- `data/`: approximately 1.5 GiB of historical local datasets;
- `tofu/**/.terraform/` and `tofu/gcp/bootstrap/.bootstrap-state/`: old provider caches and GCP state material;
- `terraform/**/terraform.tfstate*`: old DigitalOcean state and backups;
- `.venv/`, Python caches and package metadata: obsolete but not yet authorized for local deletion.

Removing tracked legacy files does not remove these paths. Goal 01B must remove every one of them from the repository workspace after applying its reviewed disposition.

## Live-resource snapshot

- Google Cloud: four buckets and four service accounts were visible during the read-only pivot audit. No VM, persistent disk or reserved address was visible. Existing resources must be either adopted into the new roots or explicitly decommissioned later.
- AWS: the current login had expired. Historical project evidence says the old AWS foundation created no resources, but this must be reverified before acceptance.
- Azure: Azure CLI was not installed and no prior Azure implementation exists.
- DigitalOcean: local state records persistent object-storage buckets and a VPC; current live status was not queried. Dropping repository support does not authorize their destruction.

This is a time-specific snapshot, not a source of current truth. Every adoption or decommission task begins with a new read-only inventory.

## Required disposition

Local material is divided into two outcomes:

- **Delete:** obsolete ML artifacts/data, Python environments and caches, provider caches, generated locks and other reproducible material.
- **Archive outside the repository:** the minimum state, backup, plan, ledger and receipt set needed to adopt or decommission live historical resources. The archive must have an inventory, byte sizes and SHA-256 checksums before workspace copies are removed.

No permanent `legacy/`, archive or historical-state directory is created in this repository.

Each historical live resource must separately reach exactly one reviewed disposition:

- **adopted** into a new provider root with verified state lineage;
- **retained externally** with an owner and explicit non-management boundary; or
- **decommissioned** by a separately authorized saved plan.

Until Goal 01B receives exact target authorization:

- do not delete old state, backups, ledgers, receipts or plan files;
- do not initialize old roots in a way that changes their backend;
- do not apply or destroy from old roots;
- do not claim the pivot cleaned live infrastructure.

After Goal 01B:

- `artifacts/`, `data/`, old `tofu/`, old `terraform/`, `.gcp-runtime/`, the old virtual environment and generated Python metadata are absent from the workspace;
- only the new tracked repository and current tooling state remain;
- any required historical recovery material exists only in the verified external archive;
- live resources remain unchanged until their later adoption/decommission plans are separately authorized.
