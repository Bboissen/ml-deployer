# Goal 03: AWS

Status: **Tasks A and B accepted; runner lifecycle pending**.

The repository records prior acceptance of the state bootstrap and persistent
platform. External plan/apply evidence and fresh AWS CLI output, not this file,
must re-establish their current state before the next mutation.

## Task C1: finalize control identities

- Verify temporary source authentication and assumption of the bounded
  OpenTofu deployer role.
- Apply the exact reviewed publisher-policy extension required to read only the
  canonical `result-manifest.json` in addition to bounded log/handoff inputs.
- Implement and test the trusted publisher invocation outside the runner.
- Prove the runner cannot assume the publisher and the publisher cannot read
  arbitrary result objects.

## Task C2: publish immutable inputs

- Build the reviewed `linux/amd64` conformance image once.
- Publish it to ECR and record the immutable manifest digest.
- Upload the exact run-spec bytes to the content-addressed key and record its
  S3 version and SHA-256.

Image push and object upload are independent authorized mutations.

## Task C3: disposable runner

- Refresh account, region, quota, AMI, instance-type, empty-prefix, and backend
  evidence with AWS CLI.
- Prepare one runner saved plan bound to the accepted platform contract,
  deployer role, exact OCI digest, run-spec version, and absolute deadline.
- Apply once, observe through AWS Systems Manager/provider APIs, publish and
  verify the trusted final receipt, then destroy from runner state.
- Prove EC2, disk, instance role, schedule, and runner state are reconciled
  while S3, ECR, platform IAM/network, control evidence, and receipts remain.

No step authorizes the next one automatically.
