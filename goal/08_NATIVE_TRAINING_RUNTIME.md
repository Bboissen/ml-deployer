# Goal 08 — Native single-node ML runtime

```text
/goal Build and validate the native single-node ML runtime on GCP before introducing Ray. Keep production model code outside this infrastructure repository.

Outcome:
A disposable Standard VM or replacement-capable single Spot VM can stage a selected dataset snapshot, invoke a configurable external ML command, collect resource metrics, checkpoint restartable work, upload artifacts, and reach terminal teardown without losing accepted progress.

Runtime stack:
- Python 3.12 unless the model repository proves another version is required;
- uv or a normal venv with an exact lock file;
- Polars;
- DuckDB;
- PyArrow;
- scikit-learn;
- LightGBM;
- XGBoost;
- CatBoost;
- psutil;
- optional MLflow client only if an artifact server is later approved;
- Ray absent or disabled.

Infrastructure smoke package:
Create a small locked package set owned by this repository for synthetic tests. Do not silently inherit the existing Ray cluster's Python/Ray pins because this path has different compatibility requirements.

Execution contract:
- input layer and snapshot ID are explicit;
- dataset path is read-only;
- output run ID is unique;
- command is supplied through a reviewed config, not arbitrary unquoted shell text;
- working directory is local disk;
- stdout/stderr are captured;
- process exit code is recorded;
- wall time, peak RSS, CPU utilization, disk utilization, and I/O bytes are recorded;
- success and failure both upload diagnostics;
- secrets and signed URLs never appear in logs;
- final artifact sync occurs in a `finally` path;
- completed marker is created only after required artifacts verify in GCS;
- run state records dataset snapshot ID, schema/feature hash, fold definition, config hash, code revision, model-family adapter version, checkpoint capability, attempt number, completed work unit, and terminal status;
- resume is rejected on any incompatible hash or adapter version;
- checkpoints are written atomically to the workspace disk and selected checkpoints are copied to GCS asynchronously under immutable names.

Synthetic acceptance workload:
1. Generate or load a small Parquet fixture.
2. Scan and transform with Polars lazy execution.
3. Query with DuckDB directly over Parquet.
4. Convert only the model matrix required for training.
5. Fit tiny LightGBM, XGBoost, and CatBoost models serially.
6. Write metrics and a small model artifact for each.
7. Verify predictions are deterministic within documented tolerances.
8. Upload artifacts.

Realistic small-data smoke:
- use a bounded, non-sensitive Silver slice;
- prove memory remains within profile limits;
- prove the full dataset is not duplicated unnecessarily in pandas;
- collect load, feature, and model timings separately;
- do not optimize model quality in this infrastructure phase.

Make interface:
- make gcp-stage LAYER=silver SNAPSHOT=...
- make gcp-run-native PROFILE=smoke-paid CONFIG=...
- make gcp-pull-artifacts RUN_ID=...
- make gcp-down
- make gcp-audit

Acceptance:
- native runtime works without Ray;
- staged data is reused across the three model smoke runs;
- all artifacts arrive in GCS;
- VM and disks are deleted;
- report includes enough measurements to choose the next machine profile.

Stop condition:
Do not add Ray Tune until this phase passes.

Checkpoint adapter contract:
- expose capability as `none`, `job-boundary`, `model-continuation`, or `exact-snapshot`;
- CatBoost uses its native snapshot mechanism when the locked version and workload support it;
- XGBoost trains in bounded boosting-round chunks, saves a model checkpoint after each accepted chunk, and records any callback or early-stopping state that can be restored;
- LightGBM trains in bounded boosting-round chunks, saves a booster checkpoint, and resumes through the supported continuation interface;
- if a framework cannot reproduce required early-stopping, random-state, categorical, or callback state, do not claim exact mid-model recovery: restart only the current fold/trial from its beginning while preserving completed folds/trials;
- interrupted and uninterrupted reference runs must be compared for prediction/metric equivalence within a documented tolerance before the adapter is marked accepted.

Recovery runtime contract:
1. Mount and validate the workspace disk.
2. Validate the staged snapshot or reconstruct only invalid content.
3. Inspect immutable local run state and checkpoint records.
4. Select the highest compatible verified checkpoint.
5. Increment the attempt counter and write a recovery event.
6. Resume from the checkpoint or from the current job boundary according to adapter capability.
7. Continue periodic local checkpointing and asynchronous GCS backup.
8. On terminal success, verify final artifacts in GCS before compute and workspace-disk teardown.
9. On failure, cancellation, or expiry, upload diagnostics and apply the configured retention-or-delete policy; retained debug disks require a separate authorization and short expiry.

Spot acceptance workload:
- run a bounded model long enough to produce at least two checkpoints;
- force replacement after a verified checkpoint;
- prove the replacement VM reuses the staged cache, reattaches the same disk, resumes the accepted unit, and completes;
- prove duplicate work is bounded to at most the configured checkpoint interval or current job boundary;
- measure checkpoint write time, background upload time, warm-restart time, and total lost compute.
```
