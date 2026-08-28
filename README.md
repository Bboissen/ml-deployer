# Multi-cloud ML infrastructure

This repository provisions one disposable, single-node ML runner on AWS,
Google Cloud, or Azure. A run stays on one provider; this is not a cross-cloud
cluster.

The ML repository supplies a digest-pinned OCI image and an opaque validated
run specification. This repository owns only cloud infrastructure, native
identity, storage boundaries, runtime deadlines, and acceptance evidence.

## Current status

- AWS bootstrap and persistent platform acceptance are recorded; runner and
  trusted-publisher completion remain open.
- GCP and Azure have offline-valid bootstrap, platform, and runner roots; their
  live acceptance tasks remain open.
- [`goal/README.md`](goal/README.md) is the status index. Code, lock files,
  external saved-plan evidence, and fresh provider CLI output override prose.

## Start here

Run the complete offline suite:

```bash
make check
```

It checks repository invariants, contracts, OCI source, all nine OpenTofu
roots, provider policy regressions, and formatting. Backend initialization is
disabled and no cloud API is called.

For account setup, use the provider guide:

- [AWS](docs/account-setup/aws.md)
- [Google Cloud](docs/account-setup/gcp.md)
- [Azure](docs/account-setup/azure.md)

After authenticating manually, load the ignored `.env` binding into the current
shell:

```bash
source scripts/load-cloud-env.sh aws   # or gcp / azure
```

The loader validates names and related fields. It does not log in, enable APIs,
create identities, plan, or apply.

## Repository layout

```text
infra/<provider>/{bootstrap,platform,runner}  independent OpenTofu state roots
shared/contracts/                            provider-neutral JSON contracts
shared/bootstrap/                            portable guest execution core
shared/conformance/                          bounded OCI infrastructure smoke
scripts/                                     validators and narrow operations
tests/                                       offline contract/provider tests
docs/                                        stable design and operator guides
goal/                                        current implementation gates
```

See [architecture](docs/architecture.md), [contract](docs/contract.md), and
[lifecycle](docs/operations/lifecycle.md).

## Mutation boundary

Validation and planning are not apply authorization. Cloud apply, destroy,
import, state movement, IAM changes, image publication, and object upload each
require their own exact reviewed scope. An apply consumes the exact saved plan
that was authorized; it never silently replans.
