# Goal 09A — Recoverable AWS Spot single-node runner

```text
/goal Add an optional interruption-tolerant AWS Spot path for checkpoint-capable native ML workloads. Use one active EC2 instance, not a cluster. A single-AZ Auto Scaling Group fixed at one may recreate the instance and reattach the same run-scoped EBS workspace after interruption.

Preconditions:
- Goal 08 native runtime accepted on On-Demand;
- exact dataset snapshot and model config frozen;
- at least one checkpoint adapter accepted;
- selected Region, AZ, AZ ID, instance type, Spot quota/capacity indicators, EBS quota, and current prices recorded;
- per-run authorization includes EC2, EBS, public IPv4, recovery-window, and S3 checkpoint costs;
- no live apply without fresh one-use authorization.

Infrastructure architecture:
- separate root `tofu/aws/spot-runner/`;
- one launch template;
- one single-AZ Auto Scaling Group;
- min_size=1, max_size=1, desired_capacity=1 while active;
- Spot instances only;
- no mixed purchase options in V0;
- no scaling policies;
- no warm pool;
- no load balancer;
- no second worker;
- no distributed model training;
- one encrypted auto-delete root EBS volume;
- one separately managed encrypted EBS workspace with delete_on_termination=false because it is attached after launch and must survive instance termination;
- EBS workspace and ASG in exact same AZ;
- no Elastic IP, public ingress, key pair, Ray ports, NAT Gateway, EFS, or FSx.

EBS attachment design:
1. OpenTofu creates one workspace volume tagged with exact run_id, profile, owner, expires_at, managed_by, and data_class=ephemeral-run-state.
2. Launch template does not create a second workspace volume.
3. Instance obtains its instance ID and AZ through IMDSv2.
4. Recovery entrypoint queries only for the exact expected volume ID supplied in signed/reviewed run config, not an arbitrary tag search alone.
5. It waits until any previous attachment is fully detached and the volume is `available`.
6. Runtime role attaches the exact volume to its own instance using narrowly scoped IAM conditions.
7. It waits for `in-use`, validates filesystem UUID and local run manifest, mounts at `/mnt/spotify-ml`, and refuses to format a non-empty or previously initialized volume automatically.
8. Any attachment mismatch marks BOOTSTRAP_FAILED and does not start training.

Workspace layout:
- `/mnt/spotify-ml/cache/` verified immutable snapshots;
- `/mnt/spotify-ml/matrices/` reproducible intermediates;
- `/mnt/spotify-ml/checkpoints/` atomic framework checkpoints;
- `/mnt/spotify-ml/runs/<run_id>/state/` immutable run-state records;
- `/mnt/spotify-ml/runs/<run_id>/logs/` logs pending upload;
- `/mnt/spotify-ml/tmp/` disposable scratch.

Checkpoint rules:
- temp path, fsync, atomic rename, checksum, metadata record;
- keep previous verified checkpoint until next is locally verified and optional S3 backup completes;
- checkpoint overhead target below 3% wall time unless justified;
- S3 backup asynchronous and immutable;
- never checkpoint staged dataset;
- reject incompatible dataset, schema, fold, categorical mapping, config, code revision, architecture, library version, CUDA/driver version, or adapter version;
- if exact continuation unavailable, restart current fold/trial only.

Recovery behavior:
1. Spot interruption terminates instance; ASG attempts replacement to maintain desired capacity one.
2. EBS workspace remains and detaches.
3. Replacement is launched in same AZ.
4. Startup attaches exact workspace, validates run/expiry/cache/checkpoints.
5. Attempt count increments and immutable recovery event uploads.
6. Work resumes from highest compatible checkpoint or job boundary.
7. If local checkpoint invalid, fallback to latest verified S3 checkpoint and reconstruct invalid cache objects only.
8. If no Spot capacity, ASG remains bounded by absolute recovery deadline; no automatic On-Demand fallback.
9. After attempts or deadline, mark EXPIRED/FAILED and execute terminal cleanup.

Preemption handling:
- poll IMDSv2 Spot interruption endpoint and rebalance recommendation;
- periodic checkpoints are authoritative;
- two-minute interruption notice is best effort, not enough for a full large checkpoint;
- shutdown handler may flush logs, write event, and upload already-complete checkpoint;
- no correctness dependency on shutdown handler execution.

Deadline and terminal cleanup:
- one-time EventBridge Scheduler action at absolute deadline sets ASG min/desired capacity to zero or invokes a narrowly scoped cleanup controller;
- local runtime independently observes deadline and stops work;
- COMPLETED only after final artifacts verify in S3;
- FAILED, CANCELLED, EXPIRED upload diagnostics and terminal record;
- set ASG desired/min to zero;
- wait for instance termination and EBS detachment;
- delete ASG, launch template resources, one-time schedule, and workspace volume;
- debug volume retention only with separate authorization, owner, reason, expiry, and cost cap;
- run audit and produce teardown receipt.

Required tooling:
- scripts/aws/render_spot_run.py
- scripts/aws/checkpoint_adapter.py
- scripts/aws/recovery_entrypoint.sh
- scripts/aws/spot_status.py
- scripts/aws/spot_cancel.py
- scripts/aws/audit_orphan_run_volumes.py
- scripts/aws/attach_workspace_volume.py
- tests for manifest compatibility, attachment authorization, checkpoint ordering, atomic writes, retry caps, expiry, teardown, and adversarial mismatches.

Make interface:
- `make aws-spot-plan PROFILE=... CONFIG=...`
- `make aws-authorize ROOT=spot-runner PROFILE=... PLAN=...`
- `make aws-spot-up PROFILE=... CONFIG=... AUTH=...`
- `make aws-spot-status RUN_ID=...`
- `make aws-spot-cancel RUN_ID=...`
- `make aws-pull-artifacts RUN_ID=...`
- `make aws-audit`

Code-only acceptance:
- ASG min/max/desired other than 1 rejected for active run;
- scaling policy, warm pool, mixed On-Demand fallback, extra worker, public ingress, Elastic IP, key pair, or non-auto-delete root rejected;
- Spot without preserved EBS, checkpoint capability, attempt cap, absolute deadline, and terminal-delete policy rejected;
- volume tags complete;
- instance role cannot create arbitrary EBS volumes or attach another run's volume;
- incompatible checkpoint rejected;
- teardown plan cannot touch persistent buckets, state, network, or another run's resources.

Authorized live recovery exercise:
1. Launch small bounded Spot workload and produce at least two checkpoints.
2. Record original instance ID, ASG, launch template version, EBS volume ID, filesystem UUID, dataset READY hash, and checkpoint.
3. Use AWS Fault Injection Service Spot interruption action if approved, or terminate the ASG instance without decrementing desired capacity as a lower-fidelity replacement test.
4. Prove replacement instance ID differs and same EBS volume ID is attached.
5. Prove staged cache reused without full download.
6. Prove resume from accepted checkpoint or job boundary.
7. Compare final output with uninterrupted reference within tolerance.
8. Prove final S3 artifacts.
9. Prove ASG, instance, root EBS, workspace EBS, launch template, schedule, and temporary public IPv4 are removed.
10. Record restart time, lost compute, bytes transferred, checkpoint overhead, total cost, and teardown receipt.

Stop condition:
Do not enable Spot for real training until forced-replacement and terminal cleanup pass.
```
