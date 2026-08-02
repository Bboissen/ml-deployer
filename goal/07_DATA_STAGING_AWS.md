# Goal 07 — Immutable dataset upload and local AWS staging

```text
/goal Implement and validate immutable Bronze/Silver snapshot upload, verification, and local EC2 staging so the home server uploads each accepted dataset once and future training instances fetch it from same-region S3. Recoverable Spot runs stage onto the preserved EBS workspace so a replacement instance reuses the verified cache.

Objective:
Reduce repeated home-server bandwidth and provisioning time while preserving point-in-time integrity.

Required tools:
- scripts/aws/build_manifest.py
- scripts/aws/upload_snapshot.py
- scripts/aws/verify_snapshot.py
- scripts/aws/stage_snapshot.sh
- scripts/aws/list_snapshots.py
- tests/aws/test_manifest.py
- tests/aws/test_snapshot_commit.py

Manifest fields:
- manifest_version;
- layer: bronze or silver;
- snapshot_id;
- created_at_utc;
- source_root logical name, not absolute private path;
- dataset contract/version;
- file_count;
- total_bytes;
- per-file relative path;
- per-file byte size;
- SHA-256;
- optional CRC32C if independently computed;
- Parquet row count and schema fingerprint where inexpensive;
- generator version;
- parent snapshot ID for Silver where applicable.

Path safety:
- reject absolute paths;
- reject `..` traversal;
- reject symlinks unless reviewed policy handles them;
- reject duplicate normalized paths;
- reject device files and sockets;
- reject files changed while hashing;
- reject empty or malformed manifests.

Snapshot ID:
- deterministically derived from canonical manifest content or accepted content hash;
- never timestamp-only;
- same content yields same snapshot ID.

Upload protocol:
1. Build manifest locally.
2. Assume data-publisher role through the temporary `aws login` credentials.
3. Check whether committed snapshot exists.
4. Upload missing objects to `snapshots/<id>/objects/` with create-only conditional writes.
5. Verify remote size and checksum metadata; never use multipart ETag as SHA-256.
6. Upload canonical manifest with create-only semantics.
7. Create `COMMITTED.json` last with create-only semantics.
8. Write local non-secret receipt.
9. Do not delete local source automatically.

Incremental behavior:
- use AWS CLI/API existence checks and checksums to avoid retransmitting unchanged content;
- modification time alone is insufficient;
- committed content is immutable;
- new content creates a new snapshot ID;
- multipart uploads must be aborted on failure and audited for stale parts.

Staging protocol on EC2:
1. Accept exact layer and snapshot ID.
2. Verify commit marker and manifest hash.
3. Mount approved workspace at `/mnt/spotify-ml`; verify EBS volume ID, run tag, filesystem UUID, and local run manifest.
4. Estimate disk need with safety margin for dataset, matrices, checkpoints, logs, and temp files.
5. If `/mnt/spotify-ml/cache/<layer>/<snapshot_id>/READY.json` exists, validate against remote manifest and reuse without transfer.
6. Otherwise download to `/mnt/spotify-ml/cache/<layer>/<snapshot_id>.partial`.
7. Verify every file.
8. Atomically rename to final cache path.
9. Write `READY.json` with snapshot ID, manifest hash, file count, total bytes, verification time, EBS volume ID, and filesystem UUID.
10. Make staged snapshot read-only for trials; keep separate checkpoint and run-state directories writable.
11. Native runs and HPO trials reuse the same staged data.
12. Replacement Spot instance repeats validation but not download when cache is intact.

Cost and performance guidance:
- home-to-S3 data transfer in is normally not the dominant AWS charge, but current transfer and request pricing must be checked;
- same-region S3-to-EC2 transfer treatment must be verified from current AWS pricing before claiming zero cost for the selected path;
- S3 request charges still exist;
- avoid tiny files;
- do not duplicate every snapshot into tar archives by default;
- optional transport-pack experiment only after measurement.

Offline adversarial tests:
- missing object;
- modified object;
- wrong checksum;
- duplicate path;
- traversal path;
- symlink;
- partial upload without commit marker;
- commit marker before complete upload;
- attempted overwrite;
- stale multipart upload;
- stale local partial cache;
- insufficient disk;
- interrupted download and retry.

Live fixture validation:
- upload 10-100 MB fixture;
- stage on smoke or small EC2;
- verify local manifest;
- stage again and prove no unnecessary transfer;
- delete local cache and reconstruct from S3;
- never delete committed S3 fixture during routine compute teardown.

Real dataset gate:
Only after fixture acceptance, request separate authorization to upload complete Bronze and Silver snapshots. Produce predicted object count, bytes, upload duration, request cost, and monthly storage cost before starting.

Spot-recovery staging tests:
- terminate the managed Spot instance while preserving EBS and prove the replacement accepts the same READY file;
- prove no S3 download occurs when local objects and checksums remain valid;
- corrupt one local object and reconstruct only invalid content;
- reject mismatched EBS run ID or snapshot ID;
- never expose partial cache as ready;
- record cold-stage time, warm-remount time, verification time, bytes transferred, EBS read throughput, and S3 request count separately.
```
