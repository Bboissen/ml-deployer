# AWS roots

- `bootstrap`: protected S3 remote-state bucket; local bootstrap state.
- `platform`: persistent S3 data/results, ECR, IAM boundaries, VPC/subnet,
  internet gateway, and no-ingress security group.
- `runner`: one EC2 instance, deployment IAM, public outbound address, guest
  termination, and independent EventBridge Scheduler deadline.

The accepted AWS platform resource graph is intentionally unchanged by the
cross-cloud NAT cleanup. Migrating live platform network addresses requires a
separate state-aware saved plan.

The runner assumes the bounded deployer role, recomputes the closed platform
contract, uses IMDSv2 temporary credentials, and cannot assume the trusted
publisher role. AWS Systems Manager (SSM) is the native operator path; no
inbound security-group rule or SSH endpoint is created.

Run the backend-disabled scaffold validation from the repository root:

```bash
make scaffold-test
```

For evidence-bound persistent-platform validation, use the explicit
`aws-platform-plan-test` and `aws-platform-live-check` Make targets described in
[the acceptance runbook](../../docs/operations/aws-platform-acceptance.md).
The AWS dummy lifecycle adapter and its required durable evidence inputs are
documented in
[the AWS dummy runbook](../../docs/operations/aws-dummy-lifecycle.md).
No command here authorizes plan application or cloud mutation.
