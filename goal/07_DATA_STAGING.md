# Goal 07 — Immutable dataset upload and local staging

```text
/goal Implement and validate immutable Bronze/Silver snapshot upload, verification, and local Compute Engine staging so the home server uploads each accepted dataset once and future training servers fetch it from same-region GCS. For recoverable Spot runs, stage onto the stateful workspace disk so a replacement VM reuses the verified cache instead of downloading the dataset again.

Objective:
Reduce repeated home-server bandwidth and provisioning time while preserving point-in-time data integrity.

Required tools:
- scripts/gcp/build_manifest.py
- scripts/gcp/upload_snapshot.py
- scripts/gcp/verify_snapshot.py
- scripts/gcp/stage_snapshot.sh
- scripts/gcp/list_snapshots.py
- tests/gcp/test_manifest.py
- tests/gcp/test_snapshot_commit.py

Manifest fields:
- manifest_version;
- layer: bronze or silver;
- snapshot_id;
- created_at_utc;
- source_root logical name, not an absolute private path;
- dataset contract/version;
- file_count;
- total_bytes;
- per-file relative path;
- per-file byte size;
- SHA-256;
- optional CRC32C;
- Parquet row count and schema fingerprint where inexpensive;
- generator version;
- parent snapshot ID for Silver where applicable.

Path safety:
- reject absolute paths;
- reject `..` traversal;
- reject symlinks unless a reviewed policy explicitly handles them;
- reject duplicate normalized paths;
- reject device files and sockets;
- reject files changed during hashing;
- reject empty or malformed manifests.

Snapshot ID:
- deterministically derived from canonical manifest content or an accepted content hash;
- never based solely on current timestamp;
- same content yields same snapshot ID.

Upload protocol:
1. Build manifest locally.
2. Check whether committed snapshot already exists.
3. Upload missing objects to `snapshots/<id>/objects/` using publisher impersonation.
4. Use generation preconditions to prevent overwrite.
5. Verify remote size and checksum.
6. Upload canonical manifest.
7. Create `COMMITTED.json` last with `if-generation-match=0`.
8. Write local non-secret receipt.
9. Do not delete local source automatically.

Incremental behavior:
- use `gcloud storage rsync` or API-level existence checks to avoid retransmitting unchanged objects;
- do not compare modification time alone;
- refuse mutation of committed content;
- new content creates a new snapshot ID.

Staging protocol on VM:
1. Accept exact layer and snapshot ID.
2. Verify commit marker and manifest signature/hash.
3. Mount the approved workspace disk at `/mnt/spotify-ml` and verify its run label/manifest before use.
4. Estimate required disk space with safety margin for dataset cache, model matrix, checkpoints, logs, and temporary files.
5. If `/mnt/spotify-ml/cache/<layer>/<snapshot_id>/READY.json` exists, validate it against the remote committed manifest and reuse the cache without transfer.
6. Otherwise download to `/mnt/spotify-ml/cache/<layer>/<snapshot_id>.partial`.
7. Verify every file.
8. Atomically rename to the final cache path.
9. Write a local `READY.json` containing snapshot ID, manifest hash, file count, total bytes, verification time, and disk identifier.
10. Make the staged snapshot read-only for trials while keeping separate checkpoint and run-state directories writable.
11. Multiple native runs or HPO trials reuse the same staged data.
12. A replacement Spot VM must repeat validation, not repeat download, when the cache is intact.

Cost and performance guidance:
- GCS inbound upload is not billed by GCP, though the local ISP still carries traffic;
- same-region GCS-to-VM reads avoid GCS outbound transfer charges;
- request charges still exist;
- avoid pathological tiny-file counts;
- do not duplicate every snapshot into tar archives by default;
- add an optional transport-pack experiment only if measurements prove object count is a bottleneck.

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
- stale local partial cache;
- insufficient disk;
- interrupted download and retry.

Live fixture validation:
- upload 10-100 MB fixture;
- stage it on e2-micro or small VM;
- verify local manifest;
- stage again and prove no unnecessary transfer;
- delete local cache and reconstruct from GCS;
- never delete the committed GCS fixture during routine compute teardown.

Real dataset gate:
Only after fixture acceptance, request separate authorization to upload complete Bronze and Silver snapshots. Produce predicted object count, bytes, upload duration, and monthly storage cost before starting.

Spot-recovery staging tests:
- recreate the VM while preserving the workspace disk and prove the same `READY.json` is accepted;
- prove no GCS object download occurs when every local object and checksum remains valid;
- corrupt one local staged object and prove only the invalid content is reconstructed safely;
- prove a mismatched disk run ID or snapshot ID is rejected;
- prove a partial cache is never exposed as ready;
- record cold-stage time, warm-remount time, verification time, bytes transferred, and disk read throughput separately.
```
