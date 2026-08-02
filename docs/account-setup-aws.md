# AWS account and console setup

This is the only AWS Console work required for Goals 01-02. It secures the account and enables temporary human access and cost alerts. It does not create workload infrastructure.

## 1. Protect the root user

Sign in once with the root email, then open the account menu and **Security credentials**.

1. Under **Multi-factor authentication (MFA)**, register a passkey or FIDO2 security key. Register a second recovery device if practical.
2. Under **Access keys**, confirm there are no root access keys. If one exists, first prove it is unused, then deactivate and delete it.
3. Open **Account → Alternate contacts** and set Billing, Operations, and Security contacts. Verify the primary email and phone are recoverable.
4. Sign out. Do not use root for routine OpenTofu or CLI work.

AWS supports multiple MFA devices for the root user and recommends phishing-resistant passkeys/security keys. See [root-user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html).

## 2. Confirm account and billing readiness

Open **Billing and Cost Management → Billing preferences/account details**.

1. Confirm the account is active, on the Paid plan, and has no payment or verification hold.
2. Verify payment method, legal name, address, tax status, billing currency, and Support plan. Record no payment details in Git.
3. Enable IAM user and role access to Billing so `sposhfi-admin` can view costs without root.
4. Open **Credits** and privately record balance, eligible products, and expiry. Credits lower eligible charges; they do not make an EC2 type free.

## 3. Create budget and anomaly alerts

Choose the amounts yourself before proceeding:

```bash
export AWS_MONTHLY_BUDGET_USD='25'
export AWS_ANOMALY_THRESHOLD_USD='5'
```

In **Billing and Cost Management → Budgets**:

1. Choose **Create budget → Customize (advanced) → Cost budget**.
2. Name it `spotify-predictor-monthly`; choose **Monthly**, **Recurring**, **Fixed**.
3. Enter the exact `AWS_MONTHLY_BUDGET_USD` value.
4. Add actual-cost alerts at 50%, 80%, and 100%.
5. Add forecast alerts at 80% and 100% where available.
6. Add the operator/billing email and confirm any subscription email.

In **Cost Anomaly Detection**:

1. Open **Cost monitors → Create monitor**.
2. Select the AWS-managed services monitor for this account.
3. Create an alert subscription using the exact `AWS_ANOMALY_THRESHOLD_USD`, individual alerts, and the operator email.

Budgets and anomaly detection are delayed alerts, not hard caps. The code-level controls will remain one instance, exact-plan authorization, a deadline schedule, local self-termination, and a post-run audit. See AWS’s [cost budget](https://docs.aws.amazon.com/cost-management/latest/userguide/create-cost-budget.html) and [anomaly monitor](https://docs.aws.amazon.com/cost-management/latest/userguide/getting-started-ad.html) guides.

## 4. Configure the standalone-account operator

This account does not use AWS Organizations or IAM Identity Center. Open **IAM → Users → Create user**.

1. Create `sposhfi-admin` with AWS Management Console access.
2. Require a strong password and register a passkey/security key under **Security credentials → Multi-factor authentication (MFA)**.
3. Attach `AdministratorAccess` temporarily for bootstrap and `SignInLocalDevelopmentAccess` for browser-based temporary CLI credentials.
4. Under **Security credentials → Access keys**, verify `Access keys (0)`. Never click **Create access key**.
5. Verify the root account separately has MFA enabled and `Access keys (0)`.

Live read-only verification on 2026-08-02 confirmed root MFA, zero root access keys, one MFA device for `sposhfi-admin`, zero user access keys, and both required policies. After bootstrap, remove direct `AdministratorAccess` and allow this operator to assume the narrower `spotify-tofu-deployer` role.

## 5. Configure the workstation

Install AWS CLI v2, then run:

```bash
aws configure set region us-east-1 --profile sposhfi-admin
aws configure set output json --profile sposhfi-admin
aws login --profile sposhfi-admin

export AWS_PROFILE='sposhfi-admin'
export AWS_REGION='us-east-1'
export AWS_DEFAULT_REGION='us-east-1'
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

aws sts get-caller-identity
make aws-doctor
```

The account ID is non-secret. Login-cache tokens, temporary credentials, contact data, and billing details are private and must not be copied into repository artifacts. `aws configure list --profile sposhfi-admin` must report credential type `login`.

## 6. Read-only Region, AZ, and quota review

In **Service Quotas → AWS services → Amazon Elastic Compute Cloud**, inspect:

- Running On-Demand Standard vCPUs;
- Running On-Demand G and VT vCPUs;
- All Standard Spot Instance Requests;
- All G and VT Spot Instance Requests.

Do not request a GPU quota until a specific small GPU benchmark, vCPU count, date, and runtime are approved. Do not pick the training AZ by its letter; use the stable AZ ID and confirm the intended instance type is offered there.

```bash
aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[?State==`available`].{Name:ZoneName,Id:ZoneId}' \
  --output table

aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=r7i.4xlarge,g6e.xlarge \
  --query 'InstanceTypeOfferings[].{Type:InstanceType,AZ:Location}' \
  --output table
```

## 7. Record manual evidence and run the audit

Privately confirm root MFA/no keys, contacts, Paid status, billing access, budget recipients/thresholds, anomaly subscription, Support plan, and optional credit expiry. Then:

```bash
export AWS_MANUAL_ACCOUNT_EVIDENCE_CONFIRMED='true'
make aws-account-check
scripts/aws/account_check.sh --json
```

The audit remains read-only. It must show `PASS` before Goal 03. A `WARN` inventory count requires review; `FAIL` or `MANUAL_EVIDENCE_REQUIRED` is a stop.

## Do not create in the console

Do not manually create S3 buckets, IAM workload roles, VPCs, subnets, security groups, key pairs, EC2/EBS resources, launch templates, Auto Scaling groups, EventBridge schedules, NAT Gateways, or Elastic IPs. Later reviewed OpenTofu plans own them.
