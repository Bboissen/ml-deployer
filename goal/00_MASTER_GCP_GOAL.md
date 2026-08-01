# Goal 00 — Master GCP implementation

```text
/goal Extend this repository with a secure, cost-controlled GCP OpenTofu implementation for persistent ML object storage and disposable single-node training. Preserve the existing DigitalOcean/Ray implementation and do not stop until every local validation passes. Do not create live resources unless a later phase explicitly carries a human authorization.

Fixed project constants:
- project_id: example-project
- region: us-central1
- initial zone: us-central1-a
- state bucket: example-project-tofu-state
- bronze bucket: example-project-bronze
- silver bucket: example-project-silver
- artifact bucket: example-project-artifacts

Outcome:
1. Bootstrap a private, versioned GCS OpenTofu state bucket.
2. Create private regional Standard GCS buckets for Bronze, Silver, and artifacts.
3. Create a custom VPC, subnet, IAP-only SSH rule, OS Login, and least-privilege identities.
4. Provision exactly one active Ubuntu training VM per run; Standard runs use a direct disposable instance and recoverable Spot runs use a target-size-1 stateful managed instance group.
5. Stage immutable datasets from GCS to a local workspace disk and reuse a verified staged cache across Spot VM replacement.
6. Run native Polars, DuckDB, PyArrow, LightGBM, XGBoost, and CatBoost smoke workloads.
7. Checkpoint restartable work to the workspace disk, asynchronously back up selected checkpoints and recovery events to GCS, and return final logs, metrics, and artifacts before teardown.
8. Add optional local Ray Tune only after the native path and Spot recovery path pass.
9. Add plan policy, one-use authorization, maximum runtime, bounded recovery attempts, explicit terminal cleanup, and resource-audit controls.
10. Document the entire account and operational path for a first-time GCP user.

Architecture rulings:
- Use native Google Cloud Storage, not an external S3-compatible provider.
- Keep buckets and compute in us-central1.
- Use regional Standard storage for V0.
- Keep state, Bronze, Silver, and artifacts in separate buckets.
- Use one active VM per run, not a cluster and not distributed single-model training. A replacement Spot VM may take over the same run after preemption.
- Use e2-micro only for infrastructure smoke.
- Use native libraries first.
- Ray is disabled by default and later runs locally on the same server.
- Do not create service-account JSON keys or HMAC keys.
- Administrative SSH uses IAP and OS Login.
- An ephemeral external IPv4 may be used only for outbound bootstrap when a profile explicitly permits it; public inbound remains forbidden.
- Every VM has max_run_duration and instance_termination_action=DELETE.
- Standard-run boot and workspace disks auto-delete. Recoverable Spot runs use an auto-delete boot disk plus one run-scoped stateful workspace disk that survives VM recreation only until the run reaches COMPLETED, FAILED, CANCELLED, or EXPIRED.
- GCS is the durable backup and artifact plane, not the active training filesystem. Periodic checkpoint writes are local and GCS synchronization is asynchronous.
- Persistent platform resources have prevent_destroy and are excluded from routine compute teardown. Run-scoped stateful workspace disks are disposable, labeled with run_id and expires_at, and must be explicitly deleted at terminal teardown.

Required repository areas:
- prompts/gcp/
- tofu/gcp/bootstrap/
- tofu/gcp/storage/
- tofu/gcp/network/
- tofu/gcp/training-node/
- tofu/gcp/spot-runner/
- tofu/modules/gcp-*/
- configs/gcp/
- scripts/gcp/
- tests/gcp/
- docs/*-gcp.md
- artifacts/progress/, artifacts/receipts/, artifacts/audits/

Required local verification surface:
1. Existing repository tests still pass.
2. tofu fmt -check -recursive passes.
3. Every root initializes with -backend=false where appropriate and validates.
4. Shell scripts pass shellcheck.
5. Python utilities pass ruff and pytest.
6. OpenTofu plan JSON policy tests pass for allowed and adversarial fixtures.
7. Authorization receipt tests prove expiry, one-use behavior, project binding, root binding, profile binding, and plan-hash binding.
8. Snapshot-manifest tests prove missing, modified, duplicate, traversal, symlink, overwrite, and partial-upload rejection.
9. Secret scans show no credentials, tokens, state, plans, data, model artifacts, or authorization material committed.
10. Documentation commands are internally consistent.
11. Spot-recovery tests prove a target-size-1 runner recreates one VM, reattaches the same workspace disk, validates run and dataset hashes, resumes from an accepted checkpoint, and deletes all run-scoped resources after terminal completion.

Live-resource rule:
Do not run gcloud API enablement, project mutation, billing mutation, IAM mutation, bucket creation, object upload, VM creation, apply, or destroy without the explicit authorization defined in the relevant phase.

Iteration policy:
Work in small milestones. After each milestone, run the smallest relevant check. If it fails, diagnose and fix it before expanding scope. Record completed work, exact commands, failures, corrections, and remaining human gates in artifacts/progress/gcp.md.

Definition of done:
A new operator can follow the docs, validate the project, bootstrap protected state, create private data buckets, run an authorized e2-micro smoke VM, prove GCS read/write and automatic deletion, run one checkpoint-capable Spot workload through forced VM replacement and resume, plan larger machine profiles safely, and audit that no unexpected billable resources remain. The existing DigitalOcean implementation continues to work.
```
