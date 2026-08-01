# Goal 09A — Recoverable Spot single-node runner

```text
/goal Add an optional interruption-tolerant Spot execution path for checkpoint-capable native ML workloads. Use one active VM, not a cluster. A target-size-1 stateful managed instance group may recreate the VM and reattach the same run-scoped workspace disk after preemption.

Preconditions:
- Goal 08 native runtime accepted on Standard compute;
- exact dataset snapshot and model config are frozen;
- at least one model-family checkpoint adapter is accepted;
- selected zone, machine type, Spot quota/capacity, disk quota, and current price are recorded;
- per-run authorization includes VM, disk, recovery-window, and GCS checkpoint costs;
- no live apply without a fresh one-use authorization.

Infrastructure architecture:
- separate root: `tofu/gcp/spot-runner/`;
- one instance template;
- one zonal managed instance group with target size exactly 1;
- provisioning model SPOT;
- instance termination action DELETE;
- no autoscaler;
- no rolling surge;
- no second worker;
- no distributed XGBoost, LightGBM, CatBoost, Ray, or data processing;
- one auto-delete boot disk;
- one separately managed zonal workspace disk configured as stateful/preserved for instance recreation;
- workspace disk mounted at `/mnt/spotify-ml` by stable device name or filesystem UUID;
- no static IP, load balancer, NAT, public SSH, or Ray ports.

Workspace-disk layout:
- `/mnt/spotify-ml/cache/` verified immutable staged snapshots;
- `/mnt/spotify-ml/matrices/` reproducible model-ready intermediates;
- `/mnt/spotify-ml/checkpoints/` atomic framework checkpoints;
- `/mnt/spotify-ml/runs/<run_id>/state/` immutable local run-state records;
- `/mnt/spotify-ml/runs/<run_id>/logs/` local logs pending upload;
- `/mnt/spotify-ml/tmp/` disposable scratch only.

Checkpoint rules:
- write to a temporary path, fsync, atomically rename, then record checksum and metadata;
- keep the previous verified checkpoint until the next one is locally verified and its optional GCS backup completes;
- checkpoint cadence is measured and configured so serialization plus required synchronization remains below 3% of wall time unless explicitly justified;
- GCS backup is asynchronous and uses immutable object names;
- never upload the entire staged dataset as a checkpoint;
- never resume across mismatched dataset snapshot, feature/schema hash, fold definition, categorical mapping, model config, code revision, or adapter version;
- if mid-model continuation is not exact enough, resume from the start of the current fold/trial and preserve completed folds/trials.

Recovery behavior:
1. The MIG notices the managed instance is absent and recreates one when Spot capacity is available.
2. The same stateful workspace disk is reattached.
3. Startup verifies disk identity, run ID, expiry, dataset cache, and run-manifest hashes.
4. Startup selects the highest compatible verified checkpoint.
5. Attempt count increments and an immutable recovery event is uploaded.
6. The workload resumes according to the adapter capability.
7. If the local disk/checkpoint is invalid, fall back to the latest verified GCS checkpoint and reconstruct the staged snapshot from GCS.
8. If no capacity is available, remain in bounded retry until the recovery deadline; do not create an on-demand VM automatically.
9. After max attempts or deadline, mark the run EXPIRED or FAILED and execute terminal cleanup.

Preemption handling:
- periodic checkpoints are authoritative for recovery;
- the shutdown script is best effort only and must finish quickly;
- shutdown may flush logs, write a preemption event, and upload an already-complete checkpoint, but it must not attempt a full dataset or large checkpoint serialization from scratch;
- failure to receive or finish the shutdown script must not prevent recovery.

Terminal cleanup:
- COMPLETED is created only after final required artifacts verify in GCS;
- FAILED, CANCELLED, and EXPIRED upload diagnostics and a terminal record;
- set the MIG target size to zero or destroy the MIG;
- remove per-instance preserved-state configuration and stale template resources;
- detach and explicitly delete the run-scoped workspace disk;
- retain a debug disk only with a separate authorization, named owner, reason, expiry, and maximum cost;
- run `gcp-audit` and produce a teardown receipt proving no VM, boot disk, workspace disk, external IP, MIG, or obsolete template remains.

Required tooling:
- `scripts/gcp/render_spot_run.py`;
- `scripts/gcp/checkpoint_adapter.py`;
- `scripts/gcp/recovery_entrypoint.sh`;
- `scripts/gcp/spot_status.py`;
- `scripts/gcp/spot_cancel.py`;
- `scripts/gcp/audit_orphan_run_disks.py`;
- tests for run-manifest compatibility, checkpoint ordering, atomic writes, retry caps, expiry, teardown, and adversarial mismatches.

Make interface:
- `make gcp-spot-plan PROFILE=... CONFIG=...`;
- `make gcp-authorize ROOT=spot-runner PROFILE=... PLAN=...`;
- `make gcp-spot-up PROFILE=... CONFIG=... AUTH=...`;
- `make gcp-spot-status RUN_ID=...`;
- `make gcp-spot-cancel RUN_ID=...`;
- `make gcp-pull-artifacts RUN_ID=...`;
- `make gcp-audit`.

Code-only acceptance:
- target size other than 1 is rejected;
- autoscaler, surge, extra worker, public ingress, static IP, or non-auto-delete boot disk is rejected;
- Spot without a stateful workspace disk, checkpoint capability, attempt cap, absolute deadline, and terminal-delete policy is rejected;
- disk labels include run_id, profile, owner, expires_at, managed_by, and data_class=ephemeral-run-state;
- incompatible checkpoint metadata is rejected;
- teardown plan cannot touch Bronze, Silver, artifacts bucket, state bucket, or another run's disk.

Authorized live recovery exercise:
1. Launch a small bounded Spot workload and produce at least two checkpoints.
2. Record the original VM name, instance ID, workspace-disk name, dataset READY hash, and accepted checkpoint.
3. Force managed-instance recreation rather than waiting for a random preemption.
4. Prove the replacement has a different instance ID while the same workspace disk is attached.
5. Prove the staged cache is verified and reused without full download.
6. Prove the workload resumes from the accepted checkpoint or current job boundary.
7. Compare final output with an uninterrupted reference run within documented tolerance.
8. Prove final artifacts exist in GCS.
9. Prove MIG, VM, boot disk, workspace disk, and temporary addresses are removed.
10. Record restart time, lost compute, bytes transferred, checkpoint overhead, total cost, and teardown receipt.

Stop condition:
Do not enable Spot for real training profiles until the forced-replacement exercise and terminal cleanup pass.
```
