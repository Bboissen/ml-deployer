# Goal 02 — Repository scaffold and provider separation

```text
/goal Add the GCP scaffold and provider-neutral interfaces to Bboissen/Ray_terraform without breaking or rewriting the existing DigitalOcean implementation. Make no cloud mutations.

Required analysis:
1. Read GOAL.md, AGENTS.md, README.md, Makefile, docs/security.md, docs/cost-control.md, docs/architecture.md, and the existing storage authorization/controller logic.
2. Preserve existing targets and behavior.
3. Reuse the existing principles: persistent storage separate from disposable compute, explicit human gates, one-use authorization, no secrets in state/cloud-init, and complete teardown.
4. Do not force a repository-wide terraform/ to tofu/ rename if it creates avoidable churn. Provider separation matters more than cosmetic renaming.

Create:
- prompts/gcp/
- tofu/gcp/bootstrap/
- tofu/gcp/storage/
- tofu/gcp/network/
- tofu/gcp/training-node/
- tofu/gcp/spot-runner/
- configs/gcp/
- scripts/gcp/
- tests/gcp/
- docs/architecture-gcp.md
- docs/security-gcp.md
- docs/cost-control-gcp.md
- docs/runbook-gcp-storage.md
- docs/runbook-gcp-compute.md
- docs/disaster-recovery-gcp.md

Environment contract:
- GCP_PROJECT_ID=example-project
- GCP_REGION=us-central1
- GCP_ZONE=us-central1-a
- GCP_ADMIN_EMAIL
- GCP_BILLING_ACCOUNT_ID
- GCP_TOFU_DEPLOYER_SERVICE_ACCOUNT
- GCP_TRAINING_SERVICE_ACCOUNT
- GCP_STATE_BUCKET=example-project-tofu-state
- GCP_BRONZE_BUCKET=example-project-bronze
- GCP_SILVER_BUCKET=example-project-silver
- GCP_ARTIFACT_BUCKET=example-project-artifacts
- GCP_MAX_AUTHORIZED_COST
- GCP_MAX_RUNTIME_MINUTES
- GCP_MAX_RECOVERY_ATTEMPTS
- GCP_RECOVERY_DEADLINE_MINUTES

Machine profile schema:
- profile_name
- execution_mode: DIRECT_INSTANCE or SPOT_STATEFUL_MIG
- machine_type
- provisioning_model: STANDARD or SPOT
- boot_disk_type
- boot_disk_size_gb
- workspace_disk_enabled
- workspace_disk_type
- workspace_disk_size_gb
- workspace_disk_preserve_on_recreate
- delete_workspace_on_terminal_state
- checkpoint_mode: NONE, JOB_BOUNDARY, or MID_MODEL
- checkpoint_interval_seconds
- gcs_backup_interval_seconds
- max_recovery_attempts
- recovery_deadline_minutes
- external_ipv4_enabled
- max_run_duration
- instance_termination_action, fixed to DELETE for disposable VM instances
- allow_ray
- allow_gpu
- required_min_memory_gb
- max_estimated_cost
- labels

Make targets:
- gcp-doctor
- gcp-account-check
- gcp-fmt
- gcp-validate
- gcp-test
- gcp-bootstrap-init
- gcp-bootstrap-plan
- gcp-storage-init
- gcp-storage-plan
- gcp-network-init
- gcp-network-plan
- gcp-compute-init
- gcp-compute-plan PROFILE=...
- gcp-spot-init
- gcp-spot-plan PROFILE=... CONFIG=...
- gcp-authorize ROOT=... PROFILE=... PLAN=...
- gcp-up ROOT=... PROFILE=... AUTH=...
- gcp-spot-status RUN_ID=...
- gcp-spot-cancel RUN_ID=...
- gcp-verify
- gcp-down
- gcp-audit

Safety behavior:
- plan targets never create resources;
- apply and destroy wrappers print project, root, region, zone, profile, plan hash, authorization ID, expiry, and expected resource changes;
- apply refuses an unreviewed or stale plan;
- compute destroy cannot target storage roots;
- persistent destroy has no routine Make target;
- sensitive runtime files are mode 0600 and ignored;
- no credentials are passed as CLI arguments.

Plan policy tests must reject:
- a project other than example-project;
- a region other than us-central1 unless a future reviewed change allows it;
- more than one active VM per run or a managed instance group target size other than exactly 1;
- a non-allowlisted machine type;
- a VM without max_run_duration;
- termination action other than DELETE;
- SPOT without a checkpoint-capable config, bounded recovery attempts, a recovery deadline, and a preserved run-scoped workspace disk;
- a non-auto-delete boot disk;
- a preserved workspace disk outside the spot-runner root or without run_id, expires_at, and terminal-delete policy;
- a static external IP;
- ingress 0.0.0.0/0 or ::/0;
- public bucket IAM;
- service-account key resources;
- force_destroy=true on persistent buckets;
- deletion of any persistent resource during a compute operation.

Validation:
- existing repository checks pass;
- tofu fmt -check -recursive;
- tofu init -backend=false and tofu validate for every new root;
- shellcheck scripts/gcp/*.sh;
- ruff check and pytest tests/gcp;
- make -n gcp-up proves authorization runs before apply;
- adversarial plan fixtures are rejected.

Stop condition:
No gcloud mutation and no OpenTofu apply.

Spot recovery separation:
- keep `tofu/gcp/training-node/` for direct Standard instances and non-recoverable smoke;
- add `tofu/gcp/spot-runner/` for an instance template, a target-size-1 zonal managed instance group, one stateful run-scoped workspace disk, and its per-instance preserved-state configuration;
- do not make the Standard root conditionally emit a MIG; separate roots keep policy checks and teardown semantics auditable;
- the Spot root may preserve only the workspace disk across VM recreation; the boot disk remains disposable;
- no autoscaler and no target size above 1;
- successful, failed, cancelled, or expired runs must remove the MIG, template, per-instance configuration, and workspace disk after artifact verification.
```
