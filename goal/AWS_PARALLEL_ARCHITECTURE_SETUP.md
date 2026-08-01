# AWS console and account setup to do in parallel with coding

This is the manual path to execute while the repository work is being built. The first section is safe to do now. Later sections are gated because they create resources.

## 1. Secure the account now

1. Sign in as root once.
2. Add root MFA and a second recovery MFA device if practical.
3. Verify **Security credentials → Access keys** shows no root access keys.
4. Set Billing, Operations, and Security alternate contacts.
5. Verify payment method, legal name, address, and tax information.
6. Sign out of root and stop using it for daily work.

Record privately, not in Git:

```text
AWS account ID:
Root email:
Paid account plan confirmation:
Credit balance:
Credit expiration:
Billing currency:
```

## 2. Verify Paid-plan promotional credits and Free Tier discovery

In **Billing and Cost Management → Free Tier / Credits**, record:

- initial credit;
- earned credits;
- each expiration date;
- number of days remaining;
- Paid account plan;
- Applicable products for every active promotional credit.

Do not interpret a console instance selector as a free entitlement or credit guarantee. For the smoke profile, query `FreeTierEligible`. For every profile, separately confirm that all expected billable products are listed by the account's active promotional credit. G6e is a paid GPU family that may consume an applicable credit; it is not the smoke instance.

## 3. Configure cost monitoring now

In **Billing and Cost Management**:

1. Create monthly cost budget `spotify-predictor-monthly`.
2. Initial amount: an explicit `AWS_MONTHLY_BUDGET_USD`; USD 25-50 is recommended during validation but must not be selected silently.
3. Actual thresholds: 50%, 80%, 100%.
4. Forecast threshold: 100%.
5. Add operator email.
6. Create Cost Anomaly Detection monitor for AWS services/account.
7. Create alert subscription with a low initial threshold.
8. Free Tier usage alerts may remain enabled, but they are informational and not a project control.

These are alerts, not hard caps.

## 4. Set up the standalone-account operator now

1. Open **IAM → Users** and create `sposhfi-admin` with console access.
2. Register MFA for root and `sposhfi-admin`.
3. Verify both identities have zero access keys.
4. Attach `AdministratorAccess` temporarily and `SignInLocalDevelopmentAccess` for `aws login`.
5. After the deployer role exists, remove direct administrator access and assume that role instead.

Do not create an IAM access key, AWS Organization, or IAM Identity Center instance for V0.

## 5. Configure the workstation now

```bash
aws --version
aws configure set region us-east-1 --profile sposhfi-admin
aws login --profile sposhfi-admin
export AWS_PROFILE=sposhfi-admin
export AWS_REGION=us-east-1
aws sts get-caller-identity
```

Then record:

```bash
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "$AWS_ACCOUNT_ID"
```

Install and verify:

```bash
tofu version
git --version
make --version
python3 --version
jq --version
shellcheck --version
ruff --version
pytest --version
```

## 6. Choose Region and Availability Zone using evidence

Default V0 Region: `us-east-1`, because it generally has broad instance availability. Do not create resources until the exact Region is frozen.

Run:

```bash
aws ec2 describe-availability-zones \
  --region "$AWS_REGION" \
  --query 'AvailabilityZones[?State==`available`].[ZoneName,ZoneId]' \
  --output table
```

For each candidate type:

```bash
aws ec2 describe-instance-type-offerings \
  --region "$AWS_REGION" \
  --location-type availability-zone \
  --filters Name=instance-type,Values=g6e.8xlarge \
  --query 'InstanceTypeOfferings[].Location' \
  --output table
```

The recoverable Spot design is single-AZ because the EBS workspace cannot be attached across AZs. Select the AZ only after checking the actual target types and quotas.

## 7. Inspect quotas now; request increases in parallel when justified

Open **Service Quotas → Amazon Elastic Compute Cloud (Amazon EC2)** and inspect:

- Running On-Demand Standard instances;
- Running On-Demand G and VT instances;
- All Standard Spot Instance Requests;
- All G and VT Spot Instance Requests.

New accounts often have zero On-Demand G/VT quota. For a planned G6e test, request only enough vCPUs for the exact smallest GPU profile you intend to benchmark. Do not request g6e.8xlarge capacity before proving a smaller GPU is useful.

CLI discovery:

```bash
aws service-quotas list-service-quotas \
  --service-code ec2 \
  --region "$AWS_REGION" \
  --query 'Quotas[?contains(QuotaName, `G and VT`) || contains(QuotaName, `Standard`)].[QuotaName,Value,QuotaCode]' \
  --output table
```

Quota requests do not create EC2 resources, but they are account mutations and should be documented.

## 8. Check account defaults now

Read only:

```bash
aws s3control get-public-access-block --account-id "$AWS_ACCOUNT_ID" || true
aws ec2 get-ebs-encryption-by-default --region "$AWS_REGION"
aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=isDefault,Values=true
aws ec2 describe-instances --region "$AWS_REGION" --filters Name=instance-state-name,Values=pending,running,stopping,stopped
aws ec2 describe-volumes --region "$AWS_REGION"
aws ec2 describe-addresses --region "$AWS_REGION"
aws ec2 describe-nat-gateways --region "$AWS_REGION"
aws s3api list-buckets
```

Do not use the default VPC for the project.

## 9. Resolve bucket names now

```bash
export AWS_STATE_BUCKET="spotify-predictor-${AWS_ACCOUNT_ID}-tofu-state"
export AWS_BRONZE_BUCKET="spotify-predictor-${AWS_ACCOUNT_ID}-bronze"
export AWS_SILVER_BUCKET="spotify-predictor-${AWS_ACCOUNT_ID}-silver"
export AWS_ARTIFACT_BUCKET="spotify-predictor-${AWS_ACCOUNT_ID}-artifacts"
```

Check name availability read-only through the implementation tooling. Do not manually create buckets before Goal 03/04 apply.

## 10. Repository workflow now

```bash
git switch -c feat/aws-opentofu
```

Keep these side by side:

```text
terraform/digitalocean-workers/...
terraform/digitalocean-storage/...
tofu/aws/...
scripts/do/...
scripts/aws/...
```

Shared code should live in provider-neutral modules only when behavior is truly identical. Do not clone shared fixes into permanent cloud branches.

## 11. Human gates after code exists

Execute in this order, with a reviewed saved plan and one-use authorization each time:

1. Goal 03: bootstrap S3 state and deployer role.
2. Goal 04: create Bronze/Silver/artifact S3 buckets and runtime roles.
3. Goal 05: create VPC/network and direct compute definitions.
4. Goal 06: run free-tier-eligible smoke.
5. Goal 07: upload/stage fixture snapshot.
6. Goal 08: native ML smoke.
7. Goal 09A: forced Spot replacement on small profile.
8. Goal 09: plan and benchmark larger CPU/memory/GPU profiles.
9. Goal 10: local Ray Tune.
10. Goal 11: final audit and recovery exercises.

## 12. What not to create manually

Do not manually create:

- S3 state/data buckets;
- IAM workload roles or policies;
- IAM users/access keys;
- VPC/subnets/security groups;
- EC2 key pairs;
- EC2 instances;
- EBS volumes;
- Auto Scaling Groups;
- launch templates;
- EventBridge schedules;
- NAT Gateways;
- Elastic IPs;
- SageMaker resources;
- EKS/ECS/Batch resources.

Those belong to reviewed OpenTofu plans so teardown and audit remain reliable.

## 13. AWS-native service mapping

| Prior design concept | AWS implementation | Important difference |
|---|---|---|
| GCS backend | S3 backend with native lockfile | No DynamoDB table required for current OpenTofu native S3 locking |
| IAP + OS Login | SSM Session Manager | No inbound port or SSH key needed |
| Stateful MIG disk preservation | ASG fixed at one + separately managed EBS | Replacement bootstrap explicitly reattaches the same zonal volume |
| `max_run_duration` | EventBridge Scheduler + local systemd fallback | AWS EC2 has no identical per-instance field, so deadline enforcement is external |
| GCS regional bucket | S3 regional bucket | S3 bucket names are globally unique |
| GCP project ID | AWS account ID | Every authorization and policy must bind to exact account ID and Region |
