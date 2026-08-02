# Goal 04 — Persistent Bronze, Silver, and artifact storage on S3

```text
/goal Implement the persistent S3 storage layer for Bronze, Silver, and ML artifacts. Use the remote S3 backend with native lockfile. Complete code-only validation before any live apply.

Buckets:
- spotify-predictor-<account_id>-bronze
- spotify-predictor-<account_id>-silver
- spotify-predictor-<account_id>-artifacts

Common configuration:
- approved AWS Region;
- S3 Standard;
- account and bucket Block Public Access enabled;
- Object Ownership Bucket owner enforced; ACLs disabled;
- force_destroy=false;
- prevent_destroy=true;
- default encryption SSE-S3 for V0;
- deny non-TLS requests;
- CORS absent;
- website hosting absent;
- requester pays disabled;
- no access points in V0;
- tags for layer, project, owner, environment, managed_by.

Bronze policy:
- source truth;
- versioning enabled;
- no automatic deletion;
- no Object Lock in V0 because retention governance/compliance mode introduces operational risk;
- writes limited to data-publisher role;
- training-runtime role read-only;
- overwrite rejected by upload tooling with conditional writes.

Silver policy:
- derived but valuable;
- versioning configurable, default off unless measured need justifies cost;
- writes limited to data-publisher/data-builder role;
- training-runtime role read-only;
- no automatic deletion of accepted snapshots in V0.

Artifact policy:
- training-runtime can create new run artifacts under its run prefix but cannot overwrite accepted artifacts;
- immutable checkpoint objects and recovery events are created under run-specific prefixes;
- mutable in-place checkpoint files are never written directly to S3;
- lifecycle expiration may delete only documented temporary prefixes such as `tmp/`, `runs/unaccepted/`, and expired unpinned checkpoint backups;
- accepted/pinned artifacts and final accepted models are excluded from lifecycle deletion;
- versioning off by default unless recovery tests justify it;
- no public access.

Identity model:
- `spotify-data-publisher`: write Bronze and Silver; no state access.
- `spotify-training-runtime`: read Bronze and Silver; create artifacts under authorized run prefixes; no IAM mutation.
- `spotify-tofu-deployer`: infrastructure control; no routine dataset use.
- `sposhfi-admin` assumes roles through its temporary `aws login` session; no key files.

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
- `COMMITTED.json` is created last with an atomic conditional request equivalent to create-only semantics;
- consumers ignore snapshots without a valid commit marker;
- uploader refuses to overwrite an existing committed snapshot;
- no fake rename assumption; S3 key moves are copy plus delete.

Cost controls:
- use S3 Standard in one Region;
- no replication;
- no Transfer Acceleration;
- no Intelligent-Tiering in V0 unless measured access patterns justify monitoring and tiering fees;
- show current estimated monthly storage and request cost for 5, 10, 25, 50, and 100 GB using timestamped official pricing;
- record object counts because request charges can dominate tiny-file layouts;
- recommend Parquet objects roughly 64-256 MB where the data contract permits;
- do not enable inventory, analytics, Storage Lens advanced metrics, or CloudTrail data events by default without a cost decision.

Plan policy validation rejects:
- public principals or public ACLs;
- any wrong-region bucket;
- ACL enablement;
- force_destroy=true;
- missing prevent_destroy;
- trainer write access to Bronze/Silver;
- publisher access to state;
- Object Lock;
- unexpected lifecycle deletion on Bronze or accepted Silver;
- cross-region replication;
- Transfer Acceleration;
- KMS customer key creation in V0 unless separately approved.

Fixture live smoke after authorized apply:
1. Generate tiny local Bronze and Silver fixtures.
2. Upload through data-publisher role assumption.
3. Verify SHA-256 manifest, ETag caveats, object size, and commit marker. Do not treat multipart ETag as a content hash.
4. Read through training-runtime role.
5. Prove training-runtime cannot delete or overwrite Bronze/Silver.
6. Write a small artifact through training-runtime.
7. Prove anonymous public read fails.
8. Exercise version restore on a disposable versioned Bronze fixture object.
9. Record storage inventory and current monthly estimate.

Stop condition:
Do not upload real datasets and do not create compute in this phase.

Checkpoint and recovery-object rules:
- S3 is durable backup and evidence, not a mounted active checkpoint filesystem;
- authoritative hot checkpoint during a live Spot attempt is on the preserved EBS workspace;
- checkpoint uploads use immutable sequence names and create-only conditional requests;
- checkpoint index records framework, sequence, completed unit, checksum, byte size, dataset snapshot ID, feature/schema hash, config hash, code revision, adapter version, and source EBS volume ID;
- resume selects the highest fully uploaded and verified checkpoint whose hashes match the current run;
- never resume across incompatible dataset, fold, feature order, categorical mapping, hyperparameters, or code compatibility;
- background uploads do not block training except at configured backlog or disk-space safety thresholds;
- terminal markers are created only after required final artifacts verify in S3.
```
