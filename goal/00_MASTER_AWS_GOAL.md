# Goal 00 — Master AWS implementation

```text
/goal Extend this repository with a secure, cost-controlled AWS OpenTofu implementation for persistent ML object storage and disposable single-node training. Preserve the existing DigitalOcean. Do not stop until every local validation passes. Do not create live resources unless a later phase explicitly carries a human authorization.

Fixed and resolved constants:
- account_id: discovered with `aws sts get-caller-identity`; bind every plan and authorization to the exact 12-digit account ID
- region: us-east-1 for V0 unless Goal 01 records a better reviewed region before any resource creation
- availability_zone: selected after read-only instance-type, quota, and Spot discovery; all recoverable Spot resources remain in one AZ because EBS volumes are zonal
- state bucket: spotify-predictor-<account_id>-tofu-state
- bronze bucket: spotify-predictor-<account_id>-bronze
- silver bucket: spotify-predictor-<account_id>-silver
- artifact bucket: spotify-predictor-<account_id>-artifacts

Outcome:
1. Bootstrap a private, versioned S3 OpenTofu state bucket with native S3 lockfile locking.
2. Create private S3 Standard buckets for Bronze, Silver, and artifacts.
3. Create a custom VPC, one low-cost subnet path, no inbound administration rule, Systems Manager Session Manager access, IMDSv2 enforcement, and least-privilege IAM roles.
4. Provision exactly one active Ubuntu EC2 training instance per run. Standard runs use one direct disposable instance. Recoverable Spot runs use a single-AZ Auto Scaling Group with min_size=1, max_size=1, desired_capacity=1 and one separately managed run-scoped EBS workspace volume.
5. Stage immutable datasets from S3 to local EBS and reuse a verified staged cache after Spot replacement.
6. Run native Polars, DuckDB, PyArrow, LightGBM, XGBoost, and CatBoost smoke workloads.
7. Checkpoint restartable work to EBS, asynchronously back up selected checkpoints and recovery events to S3, and return final logs, metrics, and artifacts before teardown.
8. Add optional local Ray Tune only after the native path and Spot recovery path pass.
9. Add plan policy, one-use authorization, exact account/region binding, maximum runtime, a one-time EventBridge Scheduler deadline action, bounded recovery attempts, explicit terminal cleanup, and resource-audit controls.
10. Document the entire account and operational path for a first-time AWS user.

Architecture rulings:
- Use native Amazon S3, not an external S3-compatible provider.
- Keep S3 buckets and EC2 in the selected AWS Region.
- Use S3 Standard for V0.
- Keep state, Bronze, Silver, and artifacts in separate buckets.
- Use one active EC2 instance per run, not a cluster and not distributed single-model training.
- A replacement Spot instance may take over the same run only after validating the run manifest, EBS volume identity, dataset snapshot, and checkpoint compatibility.
- Use only a currently Free-Tier-eligible EC2 type for infrastructure smoke; discover eligibility through AWS APIs rather than hard-coding marketing assumptions.
- Native libraries first. Ray is disabled by default and later runs locally on the same instance.
- Do not create IAM user access keys, root access keys, EC2 key pairs, or static application credentials.
- Human authentication in this standalone account uses the MFA-protected `sposhfi-admin` IAM console user and AWS CLI `aws login` temporary credentials.
- Administrative shell access uses Systems Manager Session Manager. Security groups have no inbound rules.
- A public subnet and ephemeral public IPv4 may be used only for outbound bootstrap when a profile explicitly permits it. It provides no public inbound access and its current IPv4 cost must be included in the run estimate.
- No NAT Gateway in V0. A private-only profile using paid VPC interface endpoints is deferred until justified.
- Require IMDSv2, encrypted EBS, no termination protection, and an external deadline mechanism.
- Standard-run root and workspace EBS volumes use delete_on_termination=true.
- Recoverable Spot runs use an auto-delete root volume plus one separately managed encrypted run-scoped EBS workspace that survives instance termination and is explicitly deleted when the run reaches COMPLETED, FAILED, CANCELLED, or EXPIRED.
- S3 is the durable backup and artifact plane, not the active training filesystem. Periodic checkpoints are local and S3 synchronization is asynchronous.
- Persistent platform resources have lifecycle.prevent_destroy and are excluded from routine compute teardown.
- Every run-scoped resource is tagged with run_id, profile, owner, expires_at, managed_by, and data_class.
- Free Tier credits are a billing credit, not a machine reservation, not a capacity guarantee, and not proof that a GPU type is free-tier eligible.

Required repository areas:
- prompts/aws/
- tofu/aws/bootstrap/
- tofu/aws/storage/
- tofu/aws/network/
- tofu/aws/training-node/
- tofu/aws/spot-runner/
- tofu/modules/aws-*/
- configs/aws/
- scripts/aws/
- tests/aws/
- docs/*-aws.md
- artifacts/progress/, artifacts/receipts/, artifacts/audits/

Required local verification surface:
1. `tofu fmt -check -recursive` passes.
2. Every AWS root initializes with `-backend=false` where appropriate and validates.
3. Shell scripts pass shellcheck.
4. Python utilities pass ruff and pytest.
5. OpenTofu plan JSON policy tests pass for allowed and adversarial fixtures.
6. Authorization receipt tests prove expiry, one-use behavior, account binding, region binding, root binding, profile binding, and plan-hash binding.
7. Snapshot-manifest tests prove missing, modified, duplicate, traversal, symlink, overwrite, and partial-upload rejection.
8. Secret scans show no credentials, AWS login cache, tokens, state, plans, data, model artifacts, or authorization material committed.
9. Documentation commands are internally consistent.
10. Spot-recovery tests prove the target-size-1 runner creates one replacement, reattaches the same EBS workspace in the same AZ, validates hashes, resumes an accepted checkpoint, and deletes all run-scoped resources after terminal completion.
11. Deadline tests prove the EventBridge Scheduler action and local fallback cannot silently leave an instance running beyond authorization.

Live-resource rule:
Do not run account mutation, IAM mutation, S3 bucket creation, object upload, VPC creation, EC2 creation, Auto Scaling creation, EventBridge Scheduler creation, OpenTofu apply, or destroy without the explicit authorization defined in the relevant phase.

Iteration policy:
Work in small milestones. After each milestone, run the smallest relevant check. If it fails, diagnose and fix it before expanding scope. Record completed work, exact commands, failures, corrections, and remaining human gates in `artifacts/progress/aws.md`.

Definition of done:
A new operator can follow the docs, validate the account, bootstrap protected state, create private data buckets, run an authorized free-tier-eligible smoke instance, prove S3 read/write and automatic deletion, run one checkpoint-capable Spot workload through forced instance replacement and resume, plan larger CPU/memory/GPU profiles safely, and audit that no unexpected billable resources remain. Existing cloud-provider implementations continue to work.
```
