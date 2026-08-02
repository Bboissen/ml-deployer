# Goal 11 — AWS security, recovery, cost, and final acceptance

```text
/goal Perform final AWS infrastructure acceptance. Make no new billable resources unless an individual recovery exercise explicitly requires and receives authorization.

Security acceptance:
- enumerate IAM roles, policies, trust policies, instance profiles, and S3 bucket policies;
- prove no IAM users, access keys, login profiles, root access keys, or EC2 key pairs exist for this project;
- prove root MFA enabled;
- prove human access uses the MFA-protected `sposhfi-admin` IAM user with `aws login` temporary credentials and no IAM access keys;
- prove no public S3 access and account/bucket public access blocks enabled;
- prove Object Ownership Bucket owner enforced and ACLs disabled;
- prove trainer cannot access state;
- prove trainer cannot write Bronze/Silver;
- prove publisher cannot mutate infrastructure;
- prove no inbound security-group rules;
- prove Session Manager is the administrative path;
- prove IMDSv2 required;
- prove EBS encryption;
- prove no Ray ports;
- scan user-data, plans, state, logs, artifacts, shell history fixtures, and repository for secrets;
- verify deployer can pass only exact approved roles.

Cost acceptance:
- list EC2 instances, Auto Scaling Groups, launch templates, EBS volumes, snapshots, AMIs, Elastic IPs, NAT Gateways, load balancers, VPC endpoints, EFS/FSx, ECS/EKS/Batch/SageMaker/RDS resources, S3 buckets, EventBridge schedules, CloudWatch log groups, and FIS templates;
- compare inventory with allowlist;
- confirm no disposable EC2, detached run EBS, stale ASG, launch template, or deadline schedule remains;
- calculate current persistent monthly estimate;
- verify Budget and Cost Anomaly alerts;
- verify every profile has external deadline and local fallback;
- verify every Spot profile has absolute deadline, capped attempts, EBS terminal-delete policy, and orphan audit;
- verify every live run has authorization and teardown receipt;
- document that alerts are not hard caps.

State recovery exercise:
- identify current S3 state object version;
- list prior versions;
- download prior version into safe local file;
- validate without overwriting active state;
- document break-glass restore;
- do not delete current state or bucket.

Dataset recovery exercise:
- choose disposable versioned fixture object;
- delete through approved test identity;
- restore prior version/remove delete marker as appropriate;
- rerun manifest verification;
- prove committed snapshot remains valid.

Compute disaster exercise:
- run checkpoint-capable Spot smoke under fixed-size-one single-AZ ASG;
- produce at least two local checkpoints and one S3 backup;
- force managed replacement;
- prove diagnostics upload;
- prove original instance gone and replacement ID differs;
- prove same EBS volume and filesystem UUID reattached;
- prove cache validated/reused;
- prove resume from highest compatible checkpoint/job boundary;
- compare final output with uninterrupted reference;
- prove final artifacts;
- prove ASG, instance, root EBS, workspace EBS, launch template, schedule, and public IPv4 deleted;
- prove incompatible checkpoint rejected.

Deadline disaster exercise:
- run a tiny disposable instance with a very short approved deadline;
- deliberately do not invoke normal teardown;
- prove EventBridge Scheduler terminates it;
- prove schedule self-deletes after invocation;
- prove post-run audit catches and removes any failed cleanup residue;
- execute only with explicit cost authorization.

Documentation acceptance:
A first-time operator can answer:
- which AWS account, login profile, caller ARN, Region, AZ, and AZ ID are active;
- whether Free or Paid account plan is active;
- where credit balance, expiration, budget, anomaly alerts, and billing are visible;
- how to initialize and plan each root;
- which commands create billable resources;
- how to upload and identify immutable snapshots;
- how to launch cheapest smoke;
- how to launch larger CPU/memory/GPU server;
- how to inspect quota and instance availability;
- how to launch, inspect, cancel, and recover Spot run;
- difference between local hot checkpoint, S3 backup, and final artifact;
- how to connect through Session Manager;
- how to retrieve artifacts;
- how to destroy compute;
- which persistent resources remain;
- how to audit cost;
- how to recover state/data.

Final verification commands:
- `make aws-doctor`
- `make aws-account-check`
- `make aws-fmt`
- `make aws-validate`
- `make aws-test`
- `make aws-audit`
- existing DigitalOcean validation targets, excluding the frozen local VM and home-Ray surface
- `git status --short --branch`
- repository secret scan

Definition of done:
- secure persistent state, Bronze, Silver, and artifact S3 storage;
- one direct disposable EC2 path proven;
- one recoverable Spot path survives forced replacement and deletes EBS;
- native Polars/GBDT works;
- larger CPU/memory/GPU profiles safely gated;
- Ray optional and single-node;
- no unexpected billable resources;
- existing providers intact;
- live evidence and non-secret receipts archived according to policy.
```
