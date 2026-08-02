# Goal 10 — Ray Tune on one AWS instance only

```text
/goal Add Ray Tune as an optional single-node HPO mode after native training is accepted. Do not create a Ray cluster and do not expose Ray ports.

Architecture:
- one EC2 instance;
- local Ray head/runtime only;
- `ray.init()` or `ray start --head` bound to loopback/private interface;
- dashboard disabled or bound to 127.0.0.1;
- no security-group ingress;
- no worker instances;
- dataset staged once before Ray;
- every trial reads same read-only local snapshot;
- results local on EBS during run and synchronized to S3;
- Spot profile stores Ray experiment state and framework checkpoints on preserved EBS.

Compatibility:
- resolve exact Python/Ray/XGBoost/LightGBM/CatBoost matrix separately for x86_64, arm64, and GPU profiles;
- pin versions in dedicated lock files;
- do not reuse multi-node pins blindly;
- run imports and tiny-training tests before HPO;
- GPU Ray profile must validate CUDA, driver, wheel, and library versions.

Resource scheduling:
- detect physical resources;
- reserve CPU/RAM for OS, staging, SSM, checkpoint upload, and controller;
- declare per-trial CPUs, RAM assumption, and GPUs;
- cap concurrency below 75-80% measured RAM;
- no thread oversubscription;
- native model thread count equals allocated CPUs;
- GPU trials use explicit fractional/integer GPU policy only after testing; default one GPU per trial for stateful GBDT training.

HPO smoke:
- tiny synthetic objective;
- two to four concurrent CPU trials depending on profile;
- deterministic seed;
- bounded search space;
- timeout;
- FIFO before ASHA;
- real-time metrics;
- summary JSON/Markdown;
- full trial table and best config in S3.

Production HPO contract:
- external ML repository supplies objective;
- infrastructure supplies paths, resources, run ID, and artifact sink;
- leakage-free folds frozen before tuning;
- no trial redownloads dataset;
- resumable experiment state on EBS and selected immutable S3 backups for Spot;
- restore exact Ray version and supported interface;
- unsafe mid-model restore restarts only that trial;
- completed trials immutable;
- best config not auto-promoted.

Validation:
1. Native training works with Ray disabled.
2. Ray smoke works on approved paid profile.
3. Dashboard not publicly reachable.
4. CPU/native thread allocation correct.
5. Memory cap prevents unsafe concurrency.
6. Trial results survive instance deletion in S3.
7. Authorized Spot replacement reattaches EBS and restores experiment without data redownload.
8. Per-trial checkpoint compatibility and retries recorded.
9. EC2, EBS, ASG, schedule, and orphan audits clean.

Explicit non-goals:
- no multi-node Ray;
- no autoscaler;
- no Ray Data requirement;
- no distributed single-model training;
- no EKS;
- no SageMaker Hyperparameter Tuning Jobs;
- no AWS Batch in this goal.

Spot-specific limits:
- replacement starts fresh local Ray runtime and restores experiment from EBS;
- never depend on Ray process survival;
- trials checkpoint independently;
- cap trial retries and global deadline;
- completed trials not rerun unless contract explicitly permits;
- final teardown deletes EBS after S3 verification.
```
