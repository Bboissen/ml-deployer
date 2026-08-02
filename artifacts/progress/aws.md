# AWS implementation progress

## 2026-08-01 — Goals 01-02 foundation

Scope:

- provider-separated AWS scaffolds beside DigitalOcean and paused GCP;
- read-only workstation/account diagnostics;
- explicit SSO, billing, quota, Region/AZ, and image evidence contract;
- CPU and GPU plan-only profiles with separate Ubuntu AMI parameters;
- fail-closed mutation commands;
- AWS architecture, security, cost, storage, compute, and recovery docs.

Human gates remaining:

- complete the AWS Console checklist and install AWS CLI v2;
- run the live read-only account audit;
- review and accept Goals 01-02;
- implement Goal 03 separately before any state-bucket or IAM mutation.

No AWS API mutation, OpenTofu apply, destroy, instance launch, bucket creation, IAM change, quota request, or object upload was performed.

Verification:

- `make aws-fmt`: PASS.
- `make aws-validate`: PASS for bootstrap, storage, network, training-node, and spot-runner with AWS provider `6.57.1` pinned in root lock files.
- `make aws-test`: PASS, 12 tests and 34 subtests.
- `make lint-shell python-check dryrun`: PASS.
- failing audit JSON was still created mode `0600`: PASS.
- repository credential-pattern scan: PASS; no AWS key ID or private-key material found in the AWS additions.

Expected external blockers:

- `make aws-doctor`: PASS with AWS CLI `2.36.14` and OpenTofu `1.12.3` after the operator installed AWS CLI.
- live authentication verification: PASS for account `000000000000`, `sposhfi-admin`, root/user MFA, zero root/user access keys, and `aws login` credential type.
- `make aws-account-check`: partial PASS. Identity, Region, six AZs, CPU/GPU AMIs, seven candidate instance types, 33 AZ offerings, EC2 quotas, SSM access, and zero unexpected resources passed.
- remaining Goal 01 blockers: account-level S3 Block Public Access is not configured, EBS encryption-by-default is disabled, Cost Explorer data is not yet available, and the required budget/anomaly configuration does not match the local explicit values.

Correction history:

- fixed ShellCheck array-command quoting in `doctor.sh`;
- fixed Ruff import/timezone findings in `account_check.py`;
- fixed the Python test loader registration required by Python 3.14 dataclasses;
- reran OpenTofu validation outside the restricted network sandbox after the registry lookup was blocked locally.
- replaced the initial IAM Identity Center assumption with the validated standalone-account design: MFA-protected `sposhfi-admin`, no IAM access keys, AWS CLI `aws login`, and later deployer-role assumption.
