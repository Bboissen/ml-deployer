# Goal 06 — Cheapest live AWS EC2 smoke

```text
/goal Run the first bounded live AWS compute smoke using the `smoke-free` profile. This is infrastructure validation, not model training.

Preconditions:
- AWS account active;
- root/user MFA, zero IAM access keys, and `aws login` accepted;
- current credit balance and plan expiration recorded;
- state backend accepted;
- storage fixture accepted;
- network and compute plans pass policy;
- exact instance type is reported `FreeTierEligible=true` by the EC2 API for this account/region and is offered in the selected AZ;
- On-Demand Standard vCPU quota sufficient;
- exact AMI ID resolved and reviewed;
- exact plan saved and reviewed;
- one-use authorization issued;
- max authorized cost no more than the locally approved smoke cap;
- max runtime exactly 45 minutes or lower;
- EventBridge Scheduler termination action and local fallback present.

Expected resources:
- custom VPC, subnet, route table, Internet Gateway, and inbound-empty security group if not already created;
- one free-tier-eligible EC2 instance;
- one small encrypted gp3 root volume with delete_on_termination=true;
- one ephemeral public IPv4 only if the profile requires it;
- one EC2 instance profile for training runtime and SSM;
- one one-time EventBridge Scheduler schedule and narrowly scoped execution role;
- no other billable resource.

Smoke actions:
1. Apply the exact authorized plan.
2. Wait for EC2 status checks, SSM managed-instance registration, bootstrap status, and console output.
3. Connect through Session Manager.
4. Verify:
   - instance ID, type, AZ, profile, and tags;
   - CPU, RAM, and EBS size;
   - IMDSv2 required;
   - no inbound security-group rules;
   - no EC2 key pair;
   - attached IAM role identity;
   - Bronze/Silver fixture read;
   - unauthorized Bronze/Silver write fails;
   - artifact write succeeds;
   - local disk write succeeds;
   - Python and basic tools launch;
   - EventBridge deadline and local timer are active.
5. Run a tiny Polars/DuckDB synthetic smoke if memory permits.
6. Write `artifacts/runs/<run_id>/metrics.json` and `COMPLETED.json`.
7. Invoke explicit compute teardown before the 45-minute limit.
8. Prove deadline configuration through inspection. A separate automatic-termination exercise requires its own cost authorization.

Post-run audit:
- no EC2 instance;
- no root or workspace EBS volume;
- no Elastic IP;
- no snapshot or AMI;
- no Auto Scaling Group;
- no launch template;
- no active one-time schedule;
- no NAT Gateway;
- no load balancer;
- no EKS/ECS/Batch/SageMaker resource;
- persistent buckets and intentionally persistent network remain;
- artifact object exists;
- Billing/Cost Explorer later shows bounded expected usage.

Failure handling:
- capture EC2 console output, cloud-init logs, journal logs, SSM status, and non-secret diagnostics;
- upload diagnostics when possible;
- terminate compute immediately;
- consumed authorization cannot be reused;
- generate a new plan and authorization for retry.

Acceptance gate:
Pass only if the instance reads S3, writes an artifact, is administered only through Session Manager, has no inbound rule or key pair, and leaves no disposable compute resources.

Stop condition:
Do not proceed directly to a larger instance. Review smoke evidence first.
```
