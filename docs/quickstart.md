# Workstation quickstart

The provider implementations are not runnable during the clean-reset milestone. These commands validate only the repository baseline.

## Tools

Install the version declared in `mise.toml`:

```bash
mise install
```

Or install OpenTofu 1.12.x through the official OpenTofu installation method for your workstation.

## Offline checks

```bash
make check
make fmt-check
```

Both commands are offline in the current milestone. They do not authenticate to or mutate a cloud provider.

## Provider preparation

Read the provider-specific account guide before installing or authenticating its CLI:

- [`account-setup/aws.md`](account-setup/aws.md)
- [`account-setup/gcp.md`](account-setup/gcp.md)
- [`account-setup/azure.md`](account-setup/azure.md)

Do not create storage, IAM or compute manually to get ahead of the implementation goals. Bootstrap and adoption paths must be reviewed first.
