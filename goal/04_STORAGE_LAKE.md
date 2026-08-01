# Goal 04 — Persistent Bronze, Silver, and artifact storage

```text
/goal Implement the persistent GCS storage layer for Bronze, Silver, and ML artifacts in project example-project. Use the remote GCS backend. Complete code-only validation before any live apply.

Buckets:
- example-project-bronze
- example-project-silver
- example-project-artifacts

Common configuration:
- region: us-central1;
- class: STANDARD;
- UBLA enabled;
- public access prevention enforced;
- force_destroy false;
- prevent_destroy true;
- no ACL resources;
- Google-managed encryption for V0;
- CORS disabled;
- website hosting disabled;
- requester pays disabled;
- labels for layer, project, owner, environment, managed_by.

Bronze policy:
- source truth;
- versioning enabled;
- soft delete explicitly configured;
- no automatic deletion;
- no object retention lock in V0 because lock configuration can be operationally dangerous;
- writes limited to a publisher identity;
- trainer identity is read-only;
- overwrite rejected by upload tooling.

Silver policy:
- derived but valuable;
- soft delete enabled;
- versioning configurable, default off unless measured need justifies cost;
- writes limited to a data-builder/publisher identity;
- trainer identity is read-only;
- no automatic deletion of accepted snapshots in V0.

Artifact policy:
- trainer can create new run artifacts but should not overwrite accepted artifacts;
- immutable checkpoint objects and recovery events may be created under a run-specific prefix;
- mutable in-place checkpoint files are not written directly to GCS; local atomic checkpoints are uploaded under immutable sequence names;
- lifecycle delete temporary prefixes such as `tmp/`, `runs/unaccepted/`, and expired unpinned checkpoint backups after a documented period;
- accepted/pinned artifacts and final accepted models are excluded from deletion;
- object versioning not required by default;
- soft delete configured consciously and cost impact documented.

Identity model:
- `data-publisher`: write Bronze and Silver; no state access.
- `training-runtime`: read Bronze and Silver; create artifacts; no IAM mutation.
- `tofu-deployer`: infrastructure control; no routine dataset use.
- administrator impersonates identities; no key files.

Object layout:
```text
bronze/snapshots/<snapshot_id>/manifest.json
bronze/snapshots/<snapshot_id>/objects/...
bronze/snapshots/<snapshot_id>/COMMITTED.json
silver/snapshots/<snapshot_id>/manifest.json
silver/snapshots/<snapshot_id>/objects/...
silver/snapshots/<snapshot_id>/COMMITTED.json
artifacts/runs/<run_id>/config.json
artifacts/runs/<run_id>/metrics.json
artifacts/runs/<run_id>/logs/...
artifacts/runs/<run_id>/models/...
artifacts/runs/<run_id>/checkpoints/<framework>/<sequence>.<ext>
artifacts/runs/<run_id>/checkpoint-index/<sequence>.json
artifacts/runs/<run_id>/recovery/events/<attempt>-<timestamp>.json
artifacts/runs/<run_id>/FAILED.json
artifacts/runs/<run_id>/COMPLETED.json
```

Snapshot visibility rule:
- snapshot ID is content-addressed or deterministically derived;
- objects and manifest upload first;
- `COMMITTED.json` is created last with generation precondition `if-generation-match=0`;
- consumers ignore snapshots without a valid commit marker;
- uploader refuses to overwrite an existing committed snapshot;
- no fake rename assumption because GCS object rename is copy plus delete.

Cost controls:
- use Standard regional storage;
- do not enable Autoclass;
- do not use Nearline/Coldline/Archive for active training datasets;
- show estimated monthly storage for 5, 10, 25, 50, and 100 GB;
- record object counts because request charges can dominate pathological tiny-file layouts;
- recommend Parquet objects in roughly 64-256 MB ranges where the data contract permits;
- no cross-region replication.

Plan policy validation:
Reject:
- any public member `allUsers` or `allAuthenticatedUsers`;
- any non-us-central1 bucket;
- any non-Standard class;
- force_destroy=true;
- missing prevent_destroy;
- trainer write access to Bronze/Silver;
- publisher state-bucket access;
- retention lock;
- unexpected lifecycle deletion on Bronze or accepted Silver.

Fixture live smoke after authorized apply:
1. Generate a tiny local Bronze and Silver fixture.
2. Upload through the publisher impersonation path.
3. Verify CRC32C, SHA-256 manifest, object size, and commit marker.
4. Read through training-runtime impersonation.
5. Prove training-runtime cannot delete or overwrite Bronze/Silver.
6. Write a small artifact through training-runtime.
7. Prove public anonymous read fails.
8. Exercise soft-delete restore on a disposable fixture object.
9. Record storage inventory and estimated monthly cost.

Stop condition:
Do not upload the real datasets and do not create compute in this phase.

Checkpoint and recovery-object rules:
- GCS is a durable backup and control-evidence plane, not a mounted active checkpoint filesystem;
- the authoritative hot checkpoint during a live Spot attempt is on the stateful workspace disk;
- checkpoint uploads use immutable sequence names and generation precondition `if-generation-match=0`;
- a checkpoint index records framework, sequence, completed unit, checksum, byte size, dataset snapshot ID, feature/schema hash, config hash, code revision, and source workspace-disk identifier;
- resume selects the highest fully uploaded and verified checkpoint whose hashes match the current run;
- never resume a checkpoint with a different dataset, fold, feature order, categorical mapping, hyperparameter config, or code-compatibility version;
- background uploads must not block the training process except when the configured local backlog or disk-space safety threshold is exceeded;
- terminal markers are created only after required final artifacts verify in GCS.
```
