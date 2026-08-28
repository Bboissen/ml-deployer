# AWS account setup

These steps establish basic access; they do not authorize resource creation.

## One-time account basics

1. Protect the root user with MFA and do not use it for routine work.
2. Create or select a human/SSO identity that can obtain temporary credentials.
3. Select the target region and confirm account-level S3 Block Public Access.
4. Confirm that the identity can later create the state backend and the
   deployer/publisher roles defined by the OpenTofu roots.
5. Do not create an IAM access key for this repository.

## Workstation

Install AWS CLI v2, authenticate through the organization's supported
temporary-login flow, and verify the current scope:

```bash
aws sts get-caller-identity
aws configure get region
aws service-quotas list-service-quotas --service-code ec2 --region REGION
aws ec2 describe-instances --region REGION
aws s3api list-buckets
```

Put non-secret identifiers in the ignored `.env`, then validate/load them:

```bash
source scripts/load-cloud-env.sh aws
```

## Project identities

- Source operator: temporary human/CI identity.
- Deployer: the bounded IAM role emitted by `infra/aws/platform`; the runner
  provider assumes it.
- Runtime: deployment-specific instance role created by `infra/aws/runner`.
- Publisher: distinct platform role; never attach or expose it to the runner.

AWS Systems Manager (SSM) is the native remote-management path. The runner AMI
must contain the SSM Agent, Docker, AWS CLI, and GNU coreutils. The instance
role attaches `AmazonSSMManagedInstanceCore`; the security group has no inbound
rule, so SSH and Tailscale are unnecessary for the normal workflow.

Use the checked-in example variables/backends under `infra/aws/*`. Never put
credentials in them, and never initialize placeholders against a real backend.
