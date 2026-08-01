# Goal 01 — AWS paid account, billing, identity, workstation, and image policy

```text
/goal Build a beginner-safe setup guide and read-only diagnostic tooling for an AWS Paid account used by the Spotify Predictor OpenTofu implementation. Configure account security, human access, billing visibility, budgets, anomaly alerts, local tooling, Region selection, quota discovery, and the common Ubuntu image policy. Do not create workload resources.

Fixed operating assumptions:
- account_plan: PAID
- primary_region: us-east-1
- cli_profile: sposhfi-admin
- cpu_os: Canonical Ubuntu Server 24.04 LTS, x86_64, gp3-backed
- gpu_os: AWS Deep Learning Base OSS Nvidia Driver GPU AMI, Ubuntu 24.04, x86_64
- no Amazon Linux, Debian, ARM64, or alternate OS profile in V0
- no architecture decision depends on Free Tier eligibility or promotional-credit availability

Deliverables:
- docs/account-setup-aws.md
- docs/image-policy-aws.md
- scripts/aws/doctor.sh
- scripts/aws/account_check.sh
- Make targets `aws-doctor` and `aws-account-check`
- mode-0600 JSON audit output under `artifacts/audits/`

Manual account guide requirements:

A. Root-account protection
1. Verify the root email address and registered phone are controlled, current, and recoverable.
2. Enable phishing-resistant MFA for the root user where practical; prefer a passkey or FIDO2 security key.
3. Register a second recovery MFA device when operationally possible.
4. Verify no root access key exists. If one exists, deactivate and delete it after confirming it is unused.
5. Configure valid security, operations, and billing alternate contacts.
6. Use the root user only for account-level tasks that cannot be completed through the operator role.
7. Stop if account activation, payment verification, root MFA, or account recovery information is incomplete.

B. Paid-account and billing readiness
1. Verify in Billing and Cost Management that the account plan is `Paid`.
2. Verify the account is active, the payment method is valid, and there is no billing hold, verification restriction, or unpaid balance blocking service use.
3. Record the billing currency, tax-registration status, invoice address, legal name, and default payment method without recording card or bank details in the repository.
4. Activate IAM user and role access to Billing and Cost Management so `sposhfi-admin` can inspect billing without using root.
5. Grant the operator only the billing permissions required to view costs, budgets, credits, invoices, and anomaly alerts. Do not make billing administration part of the training-runtime role.
6. Record any promotional-credit balance and expiration as optional accounting evidence.
7. State explicitly that credits reduce the invoice only while eligible and available; they do not make an instance type free and must not determine architecture.
8. State explicitly that a Paid account continues charging the configured payment method after credits expire or are exhausted.
9. Record the AWS Support plan. Basic Support is acceptable for V0 because it covers account, billing, and service-quota assistance; do not purchase a paid Support plan automatically.

C. Cost visibility and alerting
1. Enable Cost Explorer if it is not already active and document that initial data can take time to appear.
2. Require `AWS_MONTHLY_BUDGET_USD` as an explicit operator setting. Recommend USD 25-50 during infrastructure validation, but do not silently choose a value in code.
3. Create one monthly account-level cost budget using `AWS_MONTHLY_BUDGET_USD`.
4. Add actual-cost alerts at 50%, 80%, and 100%.
5. Add forecasted-cost alerts at 80% and 100% where available.
6. Send alerts to the billing and operator addresses.
7. Enable AWS Cost Anomaly Detection with an account/service monitor and an alert subscription.
8. Require an explicit anomaly threshold through `AWS_ANOMALY_THRESHOLD_USD`; recommend a low threshold during validation.
9. Document that AWS Budgets data is delayed and budget alerts are notifications, not immediate or hard spending caps.
10. Do not rely on Free Tier usage alerts as a project control. They may remain enabled if credits exist, but they are informational only.
11. Hard safeguards remain in repository code: allowlisted profiles, exact saved-plan authorization, one active instance, per-run maximum cost, deadline cleanup, local self-termination fallback, bounded Spot recovery, and post-run resource audit.
12. Do not purchase Savings Plans, Reserved Instances, Capacity Reservations, Dedicated Hosts, Marketplace subscriptions, or paid AMI products during account setup.
13. Define mandatory cost-allocation tag keys for later resources: `project`, `environment`, `owner`, `run_id`, `profile`, `managed_by`, `expires_at`, and `data_class`.

D. Human identity and temporary credentials
1. This is a standalone account; do not create AWS Organizations or IAM Identity Center for V0.
2. Use the named `sposhfi-admin` IAM user for console access only.
3. Require MFA for root and `sposhfi-admin`.
4. Attach `AdministratorAccess` temporarily for bootstrap and `SignInLocalDevelopmentAccess` for browser-based CLI login.
5. Verify root and `sposhfi-admin` each have zero IAM access keys.
6. Use AWS CLI `aws login --profile sposhfi-admin` for temporary local credentials.
7. Do not create long-lived access keys for the operator, OpenTofu, application runtime, or CI.
8. Later OpenTofu roots allow `sposhfi-admin` to assume the narrower `spotify-tofu-deployer` role, then remove direct administrator access.
9. Runtime EC2 instances use instance profiles and IAM roles, never credentials placed in user data, environment files, or state.

E. Region and Availability Zone policy
1. Use `us-east-1` for V0 unless a separately reviewed architecture decision changes it.
2. Verify the Region is enabled for the account.
3. Record available Availability Zones and stable AZ IDs.
4. Do not choose the final training AZ from its letter alone because account-specific AZ letters can map differently.
5. Select the training AZ only after checking candidate instance offerings, Spot availability, EBS constraints, and quotas.
6. Keep each run and its EBS workspace in one Availability Zone.
7. Do not enable additional opt-in Regions during this goal.

F. Common Ubuntu image policy
1. Standardize V0 on Ubuntu 24.04 LTS x86_64 for CPU and GPU nodes.
2. CPU profiles use the official Canonical Ubuntu Server 24.04 LTS AMI resolved through the Canonical public SSM parameter:
   `/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id`.
3. Verify the resolved CPU AMI owner is Canonical account `099720109477`.
4. GPU profiles use the AWS-maintained `Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)` resolved through:
   `/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id`.
5. Verify the resolved GPU AMI owner is `amazon` and the selected release supports the intended G-family instance.
6. Do not use a framework-bundled DLAMI by default. Use the Base GPU DLAMI for drivers/CUDA, then install the project’s locked Python environment separately.
7. Resolve the public SSM parameter during planning, but save and authorize an exact OpenTofu plan so the applied AMI ID cannot drift between review and apply.
8. Every run receipt records AMI ID, AMI name, owner ID/alias, architecture, creation date, source SSM parameter, and resolution timestamp.
9. Do not introduce Amazon Linux, Debian, ARM64/Graviton, Ubuntu Pro, or a second Ubuntu release in V0. A new image family requires a measured compatibility or cost justification and its own smoke tests.
10. Do not bake a custom AMI during Goal 01. Add Image Builder or Packer only after repeated bootstrap time or package-repository drift is measured as a real problem.

G. Local workstation tools
Document installation and verification for:
- AWS CLI v2;
- OpenTofu;
- git;
- make;
- Python 3.12+;
- `uv`;
- jq;
- shellcheck;
- ruff;
- pytest;
- optional trivy config scanner;
- Session Manager plugin only when required by the local AWS CLI/platform path.

The guide must record exact versions in the diagnostic output but must not require that every operator uses the same host operating system.

H. CLI authentication
Document and verify:
- `aws configure set region us-east-1 --profile sposhfi-admin`
- `aws login --profile sposhfi-admin`
- `aws sts get-caller-identity --profile sposhfi-admin`
- `export AWS_PROFILE=sposhfi-admin`
- `export AWS_REGION=us-east-1`
- `export AWS_DEFAULT_REGION=us-east-1`

Rules:
- use the current AWS CLI `login` credential provider, not static access keys;
- never store static access keys in `.env`, shell history, OpenTofu variables, backend configuration, CI secrets, or state;
- never print login access tokens, refresh tokens, role credentials, or cached token contents;
- the repository may record account ID and role ARN, but not credential material.

I. Account and security-baseline validation
Validate read-only:
- exact 12-digit AWS account ID;
- caller ARN and identity type;
- selected profile and Region;
- `us-east-1` Region status;
- available AZ names and stable AZ IDs;
- account-level S3 Block Public Access has all four controls enabled;
- EBS encryption by default is enabled in `us-east-1`;
- default VPC existence is reported but never used by this project;
- no root access key exists, using console/manual evidence where no safe delegated API path is available;
- billing console access works through `sposhfi-admin` without root;
- the monthly budget and cost-anomaly subscription exist;
- no unexpected EC2 instances, EBS volumes, snapshots, AMIs, Elastic IPs, NAT Gateways, Auto Scaling groups, launch templates, load balancers, RDS databases, EKS clusters, or S3 buckets exist.

J. Service and quota discovery
Read and record for `us-east-1`:
- Running On-Demand Standard vCPU quota;
- Running On-Demand G and VT vCPU quota;
- All Standard Spot Instance Requests vCPU quota;
- All G and VT Spot Instance Requests vCPU quota;
- EBS volume and snapshot quotas relevant to gp3 workspaces;
- Elastic IP quota, despite static addresses being forbidden;
- instance-type offerings by Availability Zone for every candidate CPU, memory, and GPU profile;
- architecture, vCPU, RAM, EBS optimization, local-instance storage, network performance, Spot support, and current-generation status;
- resolved Ubuntu CPU and GPU AMI metadata;
- account-level ability to use Systems Manager Session Manager;
- no quota increase is requested automatically.

Quota requests:
1. Quota requests are allowed as deliberate human account preparation because they do not create running workload resources.
2. Request only the smallest quota needed for an approved near-term profile.
3. GPU quota requests must name the intended instance type, vCPU requirement, Region, workload, maximum runtime, and expected testing date.
4. Do not request broad quota increases merely to maximize theoretical access.

`account_check.sh` requirements:
- strictly read-only;
- fail if AWS CLI v2 or OpenTofu is missing;
- print tool versions;
- print active login profile, account ID, caller ARN, Region, and configured AZ if present;
- validate the account ID against `AWS_ACCOUNT_ID`;
- validate `AWS_REGION=us-east-1` unless an approved override is present;
- verify the `aws login` session without printing credentials or tokens;
- verify billing/Cost Explorer read access with a bounded read-only query;
- report Paid-plan confirmation as required manual evidence when AWS exposes no suitable delegated API field;
- print relevant EC2, Spot, EBS, and Elastic IP quotas;
- print account-level S3 Block Public Access and EBS encryption-by-default status;
- resolve and inspect the Ubuntu CPU AMI and GPU DLAMI;
- reject an unexpected AMI owner, architecture, or operating-system family;
- list unexpected billable resources read-only across the enabled target Region;
- verify the local clock is reasonably synchronized;
- support `--json` and write mode-0600 audit output;
- redact contact information, payment information, invoice data, credentials, tokens, and AWS login-cache paths;
- exit nonzero for unmet mandatory prerequisites;
- distinguish `FAIL`, `WARN`, `MANUAL_EVIDENCE_REQUIRED`, and `PASS`.

Validation:
- `make aws-doctor`
- `make aws-account-check`
- `scripts/aws/account_check.sh --json`
- inspect the audit and confirm no credential, token, contact PII, payment detail, or invoice detail is present
- confirm CPU and GPU AMI owner validation passes
- confirm no Free Tier eligibility check controls the outcome
- run a repository secret scan

Stop condition:
Stop after account security, Paid-plan confirmation, billing access, budgets, anomaly alerts, `aws login` workstation setup, Ubuntu image resolution, deliberately approved quota requests, and read-only diagnostics. Do not create S3 buckets, workload IAM roles, VPC resources, EC2 instances, EBS workspaces, launch templates, Auto Scaling groups, EventBridge schedules, custom AMIs, or model artifacts.
```

## Human commands after review

```bash
export AWS_PROFILE='sposhfi-admin'
export AWS_REGION='us-east-1'
export AWS_DEFAULT_REGION='us-east-1'
export AWS_MONTHLY_BUDGET_USD='25'       # operator-selected; change deliberately
export AWS_ANOMALY_THRESHOLD_USD='5'     # operator-selected; change deliberately

aws login --profile "$AWS_PROFILE"

export AWS_ACCOUNT_ID="$(
  aws sts get-caller-identity \
    --profile "$AWS_PROFILE" \
    --query Account \
    --output text
)"

aws sts get-caller-identity \
  --profile "$AWS_PROFILE"

aws account list-regions \
  --profile "$AWS_PROFILE" \
  --region-opt-status-contains ENABLED_BY_DEFAULT ENABLED \
  --query 'Regions[].{Region:RegionName,Status:RegionOptStatus}' \
  --output table

aws ec2 describe-availability-zones \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query 'AvailabilityZones[?State==`available`].{Name:ZoneName,StableId:ZoneId,State:State}' \
  --output table

aws s3control get-public-access-block \
  --profile "$AWS_PROFILE" \
  --account-id "$AWS_ACCOUNT_ID"

aws ec2 get-ebs-encryption-by-default \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION"

CPU_AMI_ID="$(
  aws ssm get-parameter \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --name '/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id' \
    --query 'Parameter.Value' \
    --output text
)"

GPU_AMI_ID="$(
  aws ssm get-parameter \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --name '/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id' \
    --query 'Parameter.Value' \
    --output text
)"

aws ec2 describe-images \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --image-ids "$CPU_AMI_ID" "$GPU_AMI_ID" \
  --query 'Images[].{Id:ImageId,Name:Name,Owner:OwnerId,Architecture:Architecture,Created:CreationDate,State:State}' \
  --output table

aws ec2 describe-instance-types \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --instance-types \
    t3.small \
    c7i-flex.large \
    m7i-flex.large \
    r7i.large \
    g6e.xlarge \
    g6e.8xlarge \
  --query 'InstanceTypes[].{
    Type:InstanceType,
    Architectures:ProcessorInfo.SupportedArchitectures,
    vCPU:VCpuInfo.DefaultVCpus,
    MemoryMiB:MemoryInfo.SizeInMiB,
    EbsOptimized:EbsInfo.EbsOptimizedSupport,
    Spot:contains(SupportedUsageClasses, `spot`),
    CurrentGeneration:CurrentGeneration
  }' \
  --output table

aws ec2 describe-instance-type-offerings \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --location-type availability-zone \
  --filters Name=instance-type,Values=c7i-flex.large,m7i-flex.large,r7i.large,g6e.xlarge,g6e.8xlarge \
  --query 'InstanceTypeOfferings[].{AZ:Location,Type:InstanceType}' \
  --output table

aws service-quotas list-service-quotas \
  --profile "$AWS_PROFILE" \
  --service-code ec2 \
  --region "$AWS_REGION" \
  --query 'Quotas[?
    contains(QuotaName, `Running On-Demand Standard`) ||
    contains(QuotaName, `Running On-Demand G and VT`) ||
    contains(QuotaName, `All Standard Spot`) ||
    contains(QuotaName, `All G and VT Spot`) ||
    contains(QuotaName, `Elastic IP`)
  ].{Name:QuotaName,Value:Value,Code:QuotaCode,Adjustable:Adjustable}' \
  --output table
```

## Required manual console evidence

These checks may expose sensitive account or billing data and must not be copied into repository audits:

1. Billing home shows **Paid plan**.
2. Payment method and account standing are valid.
3. IAM role access to Billing is activated.
4. `sposhfi-admin` can view Billing and Cost Management.
5. Monthly budget thresholds and recipients are correct.
6. Cost Anomaly Detection monitor, threshold, frequency, and recipients are correct.
7. Root MFA and root-access-key status are accepted.
8. Primary and alternate account contacts are current.
9. Support plan is recorded.
10. Optional promotional credits and expiration are recorded privately but are not treated as infrastructure constraints.
