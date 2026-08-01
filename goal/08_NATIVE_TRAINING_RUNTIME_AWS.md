# Goal 08 — Native single-node ML runtime on AWS

```text
/goal Build and validate the native single-node ML runtime on AWS before introducing Ray. Keep production model code outside this infrastructure repository.

Outcome:
A disposable On-Demand EC2 instance or replacement-capable Spot EC2 instance can stage a selected dataset snapshot, invoke a configurable external ML command, collect resource metrics, checkpoint restartable work, upload artifacts, and reach terminal teardown without losing accepted progress.

Runtime stack:
- Python 3.12 unless the model repository proves another version is required;
- uv or venv with exact lock file;
- Polars;
- DuckDB;
- PyArrow;
- scikit-learn;
- LightGBM;
- XGBoost;
- CatBoost;
- psutil;
- boto3/aiobotocore only where needed for controlled S3/EC2 operations;
- optional NVIDIA runtime only in an explicitly GPU-enabled profile;
- Ray absent or disabled.

Architecture compatibility:
- maintain separate x86_64 and arm64 lock/acceptance paths if Graviton is used;
- do not assume all GBDT libraries, wheels, or GPU features are identical across architectures;
- a profile cannot switch architecture without a new plan, lock validation, and acceptance run.

Infrastructure smoke package:
Create a small locked package set owned by this repository for synthetic tests. Do not silently inherit the existing Ray cluster's pins.

Execution contract:
- input layer and snapshot ID explicit;
- dataset path read-only;
- output run ID unique;
- command supplied through reviewed structured config, never arbitrary unquoted shell text;
- working directory local EBS;
- stdout/stderr captured;
- process exit code recorded;
- wall time, peak RSS, CPU utilization, EBS utilization, disk I/O bytes, and network bytes recorded;
- GPU metrics collected only for GPU profiles;
- success and failure upload diagnostics;
- credentials, AWS login cache, IMDS tokens, signed URLs, and session tokens never logged;
- final artifact sync in a `finally` path;
- completed marker created only after required artifacts verify in S3;
- run state records dataset snapshot, schema/feature hash, fold definition, config hash, code revision, adapter version, checkpoint capability, attempt, completed work unit, architecture, instance type, AMI ID, and terminal status;
- incompatible resume rejected;
- checkpoints written atomically to EBS and selected checkpoints copied asynchronously to S3 under immutable names.

Synthetic acceptance workload:
1. Generate or load small Parquet fixture.
2. Scan and transform with Polars lazy execution.
3. Query with DuckDB directly over Parquet.
4. Convert only required model matrix.
5. Fit tiny LightGBM, XGBoost, and CatBoost models serially.
6. Write metrics and model artifact for each.
7. Verify deterministic predictions within documented tolerances.
8. Upload artifacts to S3.

Realistic small-data smoke:
- use bounded non-sensitive Silver slice;
- prove memory within profile limits;
- prove no unnecessary pandas/full-data duplication;
- collect load, feature, and model timings separately;
- do not optimize model quality in this phase.

Make interface:
- `make aws-stage LAYER=silver SNAPSHOT=...`
- `make aws-run-native PROFILE=smoke-paid CONFIG=...`
- `make aws-pull-artifacts RUN_ID=...`
- `make aws-down`
- `make aws-audit`

Acceptance:
- native runtime works without Ray;
- staged data reused across model smoke runs;
- artifacts reach S3;
- EC2 and run EBS resources deleted;
- deadline schedules cleaned up;
- report contains measurements for next profile choice.

Stop condition:
Do not add Ray Tune until this phase passes.

Checkpoint adapter contract:
- capability: none, job-boundary, model-continuation, or exact-snapshot;
- CatBoost native snapshot only when accepted for locked version/workload;
- XGBoost bounded boosting chunks with saved model and restorable callback/early-stopping state where possible;
- LightGBM bounded boosting chunks with supported continuation interface;
- if exact state cannot be restored, restart only current fold/trial and preserve completed work;
- compare interrupted and uninterrupted runs for predictions and metrics before adapter acceptance.

Recovery runtime contract:
1. Mount and validate EBS workspace.
2. Validate staged snapshot or reconstruct invalid content only.
3. Inspect immutable local run state and checkpoint records.
4. Select highest compatible verified checkpoint.
5. Increment attempt and write recovery event.
6. Resume according to adapter capability.
7. Continue periodic local checkpointing and asynchronous S3 backup.
8. On success, verify final S3 artifacts before ASG/instance and EBS teardown.
9. On failure, cancellation, or expiry, upload diagnostics and apply retention/delete policy; debug volume retention requires separate authorization and short expiry.

Spot acceptance workload:
- bounded model producing at least two checkpoints;
- force replacement after verified checkpoint;
- replacement reuses staged cache, reattaches same EBS, resumes accepted unit, and completes;
- duplicate work bounded by checkpoint interval or job boundary;
- measure checkpoint write, S3 upload, EBS attach/mount, warm restart, and lost compute.
```
