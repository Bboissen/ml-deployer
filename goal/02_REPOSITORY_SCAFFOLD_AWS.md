# Goal 02 — AWS repository scaffold and provider separation

```text
/goal Add the AWS scaffold and provider-neutral interfaces without breaking or rewriting the existing DigitalOcean implementation. Make no cloud mutations.

Required analysis:
1. Read AGENTS.md, README.md, Makefile, docs/security.md, docs/cost-control.md, docs/architecture.md, and the existing authorization/controller logic.
2. Preserve existing targets and behavior.
3. Reuse shared principles: persistent storage separate from disposable compute, explicit human gates, one-use authorization, no secrets in state/user-data, complete teardown, immutable dataset snapshots, and local checkpointing.
4. Keep provider-specific resources separated. Share only genuinely provider-neutral code such as authorization receipts, manifest validation, run-state contracts, model adapters, and policy-test utilities.
5. Do not create a permanent branch per cloud provider. Use a temporary `feat/aws-opentofu` branch and merge provider directories side by side.

Create:
- prompts/aws/
- tofu/aws/bootstrap/
- tofu/aws/storage/
- tofu/aws/network/
- tofu/aws/training-node/
- tofu/aws/spot-runner/
- tofu/modules/aws-s3-bucket/
- tofu/modules/aws-iam-role/
- tofu/modules/aws-ec2-profile/
- tofu/modules/aws-deadline-schedule/
- configs/aws/
- scripts/aws/
- tests/aws/
- docs/architecture-aws.md
- docs/security-aws.md
- docs/cost-control-aws.md
- docs/runbook-aws-storage.md
- docs/runbook-aws-compute.md
- docs/disaster-recovery-aws.md

Environment contract:
- AWS_PROFILE
- AWS_ACCOUNT_ID
- AWS_REGION=us-east-1
- AWS_AVAILABILITY_ZONE
- AWS_AVAILABILITY_ZONE_ID
- AWS_ADMIN_EMAIL
- AWS_TOFU_DEPLOYER_ROLE_ARN
- AWS_DATA_PUBLISHER_ROLE_ARN
- AWS_TRAINING_RUNTIME_ROLE_ARN
- AWS_SPOT_CONTROLLER_ROLE_ARN
- AWS_STATE_BUCKET=spotify-predictor-<account_id>-tofu-state
- AWS_BRONZE_BUCKET=spotify-predictor-<account_id>-bronze
- AWS_SILVER_BUCKET=spotify-predictor-<account_id>-silver
- AWS_ARTIFACT_BUCKET=spotify-predictor-<account_id>-artifacts
- AWS_MAX_AUTHORIZED_COST
- AWS_MAX_RUNTIME_MINUTES
- AWS_MAX_RECOVERY_ATTEMPTS
- AWS_RECOVERY_DEADLINE_MINUTES

Machine profile schema:
- profile_name
- execution_mode: DIRECT_INSTANCE or SPOT_SINGLE_AZ_ASG
- instance_type
- architecture: x86_64 or arm64
- purchase_model: ON_DEMAND or SPOT
- ami_parameter_name or exact reviewed AMI ID
- root_volume_type
- root_volume_size_gb
- root_volume_iops
- root_volume_throughput
- workspace_volume_enabled
- workspace_volume_type
- workspace_volume_size_gb
- workspace_volume_iops
- workspace_volume_throughput
- workspace_preserve_on_replacement
- delete_workspace_on_terminal_state
- checkpoint_mode: NONE, JOB_BOUNDARY, or MID_MODEL
- checkpoint_interval_seconds
- s3_backup_interval_seconds
- max_recovery_attempts
- recovery_deadline_minutes
- associate_public_ipv4
- max_run_duration_minutes
- deadline_schedule_enabled, fixed true for live compute
- local_termination_fallback_enabled, fixed true
- allow_ray
- allow_gpu
- accelerator_count
- required_min_memory_gb
- max_estimated_cost
- tags

Make targets:
- aws-doctor
- aws-account-check
- aws-fmt
- aws-validate
- aws-test
- aws-bootstrap-init
- aws-bootstrap-plan
- aws-storage-init
- aws-storage-plan
- aws-network-init
- aws-network-plan
- aws-compute-init
- aws-compute-plan PROFILE=...
- aws-spot-init
- aws-spot-plan PROFILE=... CONFIG=...
- aws-authorize ROOT=... PROFILE=... PLAN=...
- aws-up ROOT=... PROFILE=... AUTH=...
- aws-spot-status RUN_ID=...
- aws-spot-cancel RUN_ID=...
- aws-verify
- aws-down
- aws-audit

Safety behavior:
- plan targets never create resources;
- apply and destroy wrappers print account ID, caller ARN, region, AZ, root, profile, plan hash, authorization ID, expiry, estimated maximum cost, and expected resource changes;
- apply refuses an unreviewed or stale plan;
- compute destroy cannot target storage or bootstrap roots;
- persistent destroy has no routine Make target;
- sensitive runtime files are mode 0600 and ignored;
- no credentials are passed as CLI arguments;
- no EC2 key pair is created;
- provider authentication uses `aws login` temporary credentials and later role assumption;
- `AWS_PROFILE` and role ARN are accepted, static access keys are rejected by preflight checks.

Plan policy tests must reject:
- an AWS account other than the approved account ID;
- a region other than the approved region;
- an AZ outside the approved region;
- more than one active direct instance;
- an Auto Scaling Group whose min, max, or desired capacity differs from exactly 1 for an active Spot run;
- an autoscaling policy or warm pool;
- a non-allowlisted instance type;
- an instance without IMDSv2 required;
- an instance without encrypted EBS;
- live compute without a one-time deadline schedule and local termination fallback;
- Spot without a checkpoint-capable config, bounded attempts, absolute deadline, and preserved run-scoped EBS workspace;
- a root EBS volume with delete_on_termination=false;
- a preserved workspace outside the spot-runner root or without run_id, expires_at, and terminal-delete policy;
- Elastic IP allocation;
- inbound security-group rules;
- public S3 policies or ACLs;
- IAM users, access keys, login profiles, or EC2 key pairs;
- NAT Gateway, load balancer, RDS, EKS, ECS service, Batch environment, SageMaker domain, or other unexpected services;
- deletion of any persistent resource during a compute operation.

Validation:
- existing repository checks pass;
- `tofu fmt -check -recursive`;
- `tofu init -backend=false` and `tofu validate` for every new root;
- shellcheck `scripts/aws/*.sh`;
- ruff and pytest under `tests/aws`;
- `make -n aws-up` proves authorization runs before apply;
- adversarial plan fixtures are rejected.

Stop condition:
No account mutation, IAM mutation, S3 creation, VPC creation, or OpenTofu apply.

Spot recovery separation:
- keep `tofu/aws/training-node/` for direct On-Demand instances and non-recoverable smoke;
- keep `tofu/aws/spot-runner/` for a launch template, single-AZ Auto Scaling Group fixed at one, one separately managed encrypted EBS workspace volume, and the IAM needed to reattach only that run volume;
- do not make the direct root conditionally emit an Auto Scaling Group;
- the Spot root may preserve only the workspace volume across instance replacement; the root volume remains disposable;
- no mixed-instance fleet in V0 unless Goal 09 later approves a tightly bounded compatible set;
- successful, failed, cancelled, or expired runs remove the ASG, launch template version/resources, deadline schedule, and workspace volume after artifact verification.
```
