# AWS account setup

These steps establish basic access; they do not authorize resource creation.

## One-time account basics

1. Protect the root user with MFA and do not use it for routine work.
2. Create or select a human or Identity Center identity that can obtain
   temporary credentials. Deploy refuses static access keys and the `default`
   profile.
3. Select `us-east-1`, the reviewed CPU region, and confirm account-level S3
   Block Public Access.
4. Confirm that the identity can create the state bucket, workload bucket,
   network, IAM roles and permissions boundaries, the Lambda/Scheduler guard
   and its alarms. Deploy checks the exact permissions against its saved plans.
5. Do not create an IAM access key for this repository.
6. Optional, for unattended jobs longer than the 12-hour console sign-in: set
   up [IAM Identity Center sign-in](../operations/aws-identity-center.md) with
   `./workspace identity-center`.

## Workstation

`make` installs the pinned AWS CLI; `./workspace login --profile NAME --region
us-east-1` runs the native browser sign-in (`--method sso` for Identity Center)
and `./workspace doctor project.json` shows the resolved account and identity.

## Identities Deploy creates

- Deployer: a bounded role in the platform root that the runner provider assumes.
- Workspace instance role: created per workspace under a project permissions
  boundary; reads the dataset prefix and writes only its output prefix.
- Guard: a Lambda role that may only terminate instances it tagged.

The instance uses Session Manager with no inbound security-group rule; SSH
endpoints and VPNs are unnecessary.
