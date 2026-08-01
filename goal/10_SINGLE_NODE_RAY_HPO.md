# Goal 10 — Ray Tune on one server only

```text
/goal Add Ray Tune as an optional single-node HPO execution mode after native training is accepted. Do not create a Ray cluster and do not expose Ray ports.

Architecture:
- one GCP VM;
- Ray head/runtime local to that VM;
- `ray.init()` or `ray start --head` bound to loopback/private interface;
- dashboard disabled or bound to 127.0.0.1;
- no public Ray ports;
- no worker VMs;
- dataset staged once before Ray starts;
- every trial reads the same read-only local snapshot;
- result directory local on the workspace disk during the run and synchronized to GCS;
- for a Spot profile, the Ray experiment directory and framework checkpoints live on the stateful workspace disk and must be restorable after VM replacement.

Compatibility:
- resolve a Python/Ray/XGBoost/LightGBM/CatBoost compatibility matrix;
- pin exact versions in a dedicated lock file;
- do not blindly reuse the existing multi-node cluster pins;
- run import and tiny-training tests before HPO.

Resource scheduling:
- detect physical resources;
- reserve CPU and RAM for OS, staging, and artifact sync;
- each trial declares CPUs and optional memory assumptions;
- cap concurrent trials so aggregate peak memory remains below 75-80% of RAM;
- no oversubscription of LightGBM/XGBoost/CatBoost thread counts;
- set each trial's native library thread count to its allocated CPUs;
- GPU resources remain zero.

HPO smoke:
- tiny synthetic objective;
- two to four concurrent trials depending on profile;
- deterministic seed;
- bounded search space;
- explicit timeout;
- ASHA or simple scheduler only after basic FIFO works;
- report metrics in real time;
- generate summary JSON and Markdown;
- upload full trial table and best-config artifact.

Production-oriented HPO contract:
- external ML repository supplies objective entry point;
- infrastructure supplies paths, resources, run ID, and artifact sink;
- walk-forward folds remain leakage-free and are frozen before tuning;
- no trial rebuilds or redownloads the dataset;
- resumable experiment state is checkpointed locally to the stateful workspace disk and selected immutable backups are uploaded asynchronously if Spot is used;
- restore uses the exact Ray version and supported restore interface pinned by the compatibility matrix;
- a trial that cannot safely restore mid-model restarts only that trial, not the completed trial set;
- accepted best config is not automatically promoted to production.

Validation:
1. Native training still works with Ray disabled.
2. Ray smoke works on a paid small or larger approved profile.
3. Dashboard is not publicly reachable.
4. CPU allocation matches actual native model threads.
5. Memory cap prevents unsafe concurrency.
6. Trial results survive VM deletion in GCS.
7. On an authorized Spot profile, forced VM replacement reattaches the same workspace disk and restores the experiment without redownloading the dataset.
8. Per-trial checkpoint compatibility and retry counts are recorded.
9. Compute and orphan-disk audits are clean.

Explicit non-goals:
- no autoscaler;
- no multi-node Ray;
- no Ray Data requirement;
- no distributed single-model XGBoost/LightGBM/CatBoost;
- no Kubernetes.

Future multi-node work requires a separate architecture decision and goal pack.

Spot-specific limits:
- Ray remains single-node after recovery; the replacement VM starts a fresh local Ray runtime and restores experiment state from the preserved disk;
- never depend on the Ray head process surviving preemption;
- concurrent trials must checkpoint independently and may not share a mutable model checkpoint;
- cap trial retries and the global recovery deadline;
- completed trials are immutable and must not be rerun unless the experiment contract explicitly permits it;
- final teardown follows Goal 09A and deletes the stateful workspace disk after artifact verification.
```
