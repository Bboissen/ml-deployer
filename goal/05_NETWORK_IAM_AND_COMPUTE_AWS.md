# Goal 05 — AWS network, IAM, and disposable training node

```text
/goal Implement the AWS network, access, runtime identities, direct disposable training-node root, and provider-neutral contracts later used by a recoverable single-AZ Spot runner. Do not apply until code-only validation and explicit authorization pass.

Network root:
- custom VPC, not the default VPC;
- CIDR such as 10.91.0.0/16;
- one subnet in the selected Availability Zone, such as 10.91.10.0/24;
- Internet Gateway and default route only when the approved low-cost bootstrap profile uses an ephemeral public IPv4;
- no NAT Gateway;
- no load balancer;
- no Route 53 hosted zone;
- no VPN;
- no Transit Gateway;
- security group with zero inbound rules;
- egress explicit and documented;
- optional S3 Gateway VPC endpoint may be added only if policy and route-table behavior are tested; interface endpoints are deferred because of hourly cost.

Administrative access:
- AWS Systems Manager Session Manager is the default shell and port-forwarding path;
- no port 22 ingress;
- no EC2 key pair;
- no public SSH;
- no bastion host;
- instance profile includes the minimum Systems Manager managed-instance permissions;
- user-data installs or verifies SSM Agent before declaring bootstrap success;
- session logging to S3/CloudWatch is optional and must be cost-reviewed before enabling.

Human and deployer roles:
- human uses the MFA-protected `sposhfi-admin` console identity and temporary `aws login` credentials;
- `spotify-tofu-deployer` is assumed for OpenTofu;
- deployer can pass only the exact approved runtime and scheduler roles;
- no wildcard `iam:PassRole`;
- no IAM user or access key.

Runtime role:
- `spotify-training-runtime` role and EC2 instance profile;
- read Bronze and Silver prefixes;
- create artifacts only under an authorized run prefix;
- Systems Manager managed-instance permissions;
- read exact configuration objects if needed;
- describe its own EC2 metadata through APIs only when required;
- direct-instance role may terminate only its own tagged instance for local deadline fallback;
- no IAM mutation;
- no state-bucket access;
- no ability to create EC2 instances, volumes, or networking.

Direct On-Demand compute root requirements:
- exactly one `aws_instance`;
- Ubuntu 24.04 LTS from an exact AMI ID resolved from a reviewed SSM public parameter and frozen into the plan receipt;
- architecture matches profile, including arm64 restrictions;
- Nitro-based current-generation instance where practical;
- IMDSv2 tokens required and metadata hop limit minimized;
- detailed monitoring disabled by default unless measured need justifies cost;
- termination protection false;
- encrypted root EBS volume with delete_on_termination=true;
- optional encrypted workspace EBS block device with delete_on_termination=true;
- gp3 by default; IOPS and throughput explicit;
- no instance-store/local NVMe in V0;
- no Elastic IP;
- optional ephemeral public IPv4 only for outbound bootstrap;
- no inbound security-group rules;
- instance profile attached;
- tags: project, environment, role, run_id, profile, owner, expires_at, managed_by, data_class;
- one-time EventBridge Scheduler deadline invokes EC2 termination for the exact instance and deletes itself after completion;
- local systemd deadline timer independently calls self-termination as defense in depth;
- user-data is idempotent and contains no secrets;
- console output and journal logs available for bootstrap debugging.

External IPv4 ruling:
- low-cost smoke profiles may use an ephemeral public IPv4 for outbound package installation and SSM connectivity;
- security group remains inbound-empty;
- address is released on instance termination;
- current public IPv4 cost is included in the run estimate;
- private-only profiles using SSM interface endpoints, package mirrors, or prebuilt AMIs are deferred until justified.

Startup contract:
1. Require IMDSv2 and retrieve instance identity safely.
2. Create `/opt/spotify-ml` and `/mnt/spotify-ml`.
3. Write bootstrap status atomically to `/var/lib/spotify-ml/bootstrap-status.json`.
4. Verify local deadline timer is active before workload execution.
5. Install minimal OS packages.
6. Install locked Python environment without credentials.
7. Verify the attached IAM role through a non-secret caller identity check.
8. Run infrastructure smoke.
9. Never download real data unless an exact snapshot ID is supplied.
10. Never start Ray unless `enable_ray=true`.
11. Upload bootstrap diagnostics on failure when possible.

Initial profiles:
- smoke-free: discover a currently FreeTierEligible x86_64 or arm64 type supported by the runtime; On-Demand; 12 GB encrypted gp3 root; public IPv4 true; 45 minutes; Ray false.
- smoke-paid: `m7i-flex.large` or another discovered allowed small general-purpose type; On-Demand; 25 GB encrypted gp3; 90 minutes; Ray false.
- dev-memory: candidate memory-optimized type chosen after discovery; On-Demand; 50 GB encrypted gp3; 120 minutes; Ray false.
- larger and GPU profiles remain plan-only until Goal 09.

Plan-policy rejection rules:
- account, region, or AZ mismatch;
- more than one instance;
- unapproved instance type;
- GPU in a non-GPU profile;
- unencrypted EBS;
- root volume not auto-delete;
- preserved workspace in direct root;
- missing IMDSv2 enforcement;
- missing deadline schedule or local fallback;
- inbound security-group rule;
- Elastic IP;
- key pair;
- credentials in user-data;
- IAM user/access key;
- unexpected NAT, load balancer, database, EKS, ECS, Batch, SageMaker, FSx, EFS, or reserved-capacity resources.

Code-only validation:
- init and validate network and compute roots;
- plan network and smoke-free compute;
- policy-check JSON plan;
- unit-test user-data rendering;
- scan rendered user-data and metadata for secrets;
- test IMDSv2, EBS encryption, delete-on-termination, zero inbound, deadline schedule, and self-termination policy.

Stop condition:
No apply until the cheapest smoke authorization is separately issued.

Spot-runner boundary for Goal 09A:
- separate `tofu/aws/spot-runner/` root;
- one launch template;
- one single-AZ Auto Scaling Group with min=max=desired=1;
- Spot purchase model;
- root EBS auto-deletes;
- one separately managed encrypted EBS workspace survives instance termination;
- instance bootstrap identifies the exact run volume by tags, waits for it to become available, attaches it to itself, mounts by filesystem UUID, and validates the run manifest;
- the Spot runtime role may attach/detach only the exact tagged run volume and may not create arbitrary volumes;
- no autoscaling policies, warm pool, load balancer, public ingress, key pair, or second worker;
- startup reuses valid staged data and resumes a compatible checkpoint;
- a one-time deadline action sets the ASG desired/min capacity to zero and triggers terminal cleanup tooling; local runtime also observes the absolute deadline;
- bounded attempts and a recovery deadline prevent endless replacement;
- audit must identify orphan EBS volumes, ASGs, launch templates, schedules, and running instances.
```
