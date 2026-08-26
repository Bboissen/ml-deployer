# AWS account setup

This guide covers account and workstation readiness only. It does not authorize creating AWS resources.

## Manual account prerequisites

1. Protect the root user and enable MFA.
2. Use a named administrative identity for setup; do not use root for routine work.
3. Configure a monthly cost budget and cost-anomaly notification.
4. Confirm account-level S3 Block Public Access.
5. Select one initial region based on quota, capacity, Gold data location and credit terms.

AWS budget data is delayed, so the eventual runner deadline remains the primary compute-cost safeguard.

## Workstation authentication

Use temporary credentials. Do not create an IAM access key for this repository.

After authenticating with the supported AWS CLI flow, verify the active identity:

```bash
aws sts get-caller-identity
aws configure get region
```

The accepted provider implementation will obtain workload credentials through an EC2 instance role and IMDSv2.

## Read-only quota checks

Before selecting an instance type, inspect both On-Demand and Spot quota for the chosen region:

```bash
aws service-quotas list-service-quotas --service-code ec2
```

AWS documents a default of five vCPUs for the Standard On-Demand group and zero for most accelerator-specific groups, but the live account value is authoritative.

## OpenTofu bootstrap expectations

The AWS bootstrap goal will create a dedicated private S3 state bucket with:

- versioning;
- encryption;
- account and bucket Block Public Access;
- TLS-only access;
- native OpenTofu S3 lockfile support.

The platform goal will create separate data and results buckets. It will not upload Gold data.

## Official references

- [AWS IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [AWS EC2 instance quotas](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [S3 security best practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)
- [OpenTofu S3 backend](https://opentofu.org/docs/language/settings/backends/s3/)
