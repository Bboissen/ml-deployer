# Workstation quickstart

The provider implementations are not runnable during Goal 02. These commands validate the repository and frozen provider-neutral contracts only.

## Tools

Install the version declared in `mise.toml`:

```bash
mise install
```

Or install OpenTofu 1.12.x through the official OpenTofu installation method for your workstation.

## Offline checks

```bash
make check
make contract-test
make fmt-check
```

All three commands are offline in the current milestone. They do not authenticate to or mutate a cloud provider.

Validate one normalized request directly with:

```bash
scripts/validate-runner-request.sh shared/contracts/fixtures/valid-aws.json
scripts/hash-runner-request.sh shared/contracts/fixtures/valid-aws.json
```

Equivalent fixtures exist for AWS, Google Cloud and Azure. Invalid fixtures demonstrate the fail-closed boundary.

## Provider preparation

Read the provider-specific account guide before installing or authenticating its CLI:

- [`account-setup/aws.md`](account-setup/aws.md)
- [`account-setup/gcp.md`](account-setup/gcp.md)
- [`account-setup/azure.md`](account-setup/azure.md)

Do not create storage, IAM or compute manually to get ahead of the implementation goals. Bootstrap and adoption paths must be reviewed first.

The first parallel provider interaction is the separately reviewed read-only readiness probe described in [`operations/rights-readiness.md`](operations/rights-readiness.md). It proves visibility, not create authority.
