# Workstation quickstart

Goal 02 is accepted and offline AWS, Google Cloud and Azure scaffolds now exist.
The provider goals remain in progress: no live account, backend, plan or
deployment evidence has been accepted.

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
make scaffold-test
make fmt-check
```

These commands do not authenticate to or call a cloud API. The provider
scaffold target may download exactly locked provider packages from the
OpenTofu registry when the local cache is empty.

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

Keep one non-secret canonical value per provider fact in the ignored `.env`.
Validate a provider binding with:

```bash
make cloud-env CLOUD=gcp
```

Make recipes cannot export variables back into their parent shell. To propagate
the validated aliases used by the provider CLI, SDK and OpenTofu, source the
single loader:

```bash
source scripts/load-cloud-env.sh gcp
```

Use `aws` or `azure` instead when working in those provider roots. The loader
fails closed for missing or inconsistent account, project, region or zone
values and never reads or emits provider credentials.

The first parallel provider interaction is the separately reviewed read-only readiness probe described in [`operations/rights-readiness.md`](operations/rights-readiness.md). It proves visibility, not create authority.

## Current stop point

The next live milestone starts only after the owner manually configures
temporary provider-native authentication and confirms the intended AWS account,
GCP project and Azure tenant/subscription plus their initial regions. Run the
three read-only readiness probes in parallel first. Do not initialize a backend
or run an OpenTofu plan during that probe.

After the probe evidence is reviewed, prepare provider-specific saved bootstrap
plans. GCP additionally requires fresh historical-resource classification and
state-lineage evidence before choosing its create or adoption path. Applying
any bootstrap plan remains a later explicit authorization for that exact plan
digest.
