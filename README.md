# Independent cloud ML workspaces

This repository creates an ML-ready machine, persistent native object storage,
toolbox, authenticated terminal access and bounded lifetime on AWS, Google Cloud
or Azure. Each provider operates independently. The user connects, clones an
external ML repository and installs its project dependencies; that repository
owns scripts, datasets, transformations, training and results.

Shared foundation **2.0.0** is implemented offline. The AWS persistent foundation
is deployed; a bounded private SSH/Make job, versioned S3 verification and compute
teardown passed native acceptance in [PR24](https://github.com/Bboissen/Ray_terraform/pull/24).
The AWS deployer now implements short configuration, scoped foundation/access
onboarding, streamed local/S3/public HTTPS ingestion, generic non-root setup/run,
declared output persistence and one reviewed Deploy with durable recovery.
See the [deployer quickstart](docs/operations/aws-deployer-quickstart.md),
[operation and recovery behavior](docs/operations/aws-deploy-operation.md) and
[native acceptance scope](docs/operations/aws-native-acceptance.md).

Linux/macOS tooling and versioned source packaging have offline coverage. Generic
native deployment, clean macOS installation, real IAM/alarm behavior and controller
loss acceptance remain pending. Release publication is also pending. The native
fixture receipt does not establish the complete generic journey.
Google Cloud and Azure workspace implementation remain pending. Existing
batch roots, contracts and historical evidence remain preserved during migration.
No cross-cloud service, registry mirror, homelab, local VM or Ray cluster is needed.

The [AWS first-use guide](docs/aws-setup-guide.html) explains prerequisites and access;
the deployer quickstart above describes the current commands.

Read the [workspace interface and validation guide](docs/workspace.md),
[goals](goal/README.md), [baseline and independent provider prompts](goal/workspace/05_FOUNDATION_AND_HANDOFF.md)
and [cleanup inventory for review](goal/workspace/06_CLEANUP_INVENTORY.md).

All providers default to the supported CPU machine with the most RAM within the
selected account's remaining regional/family quotas, then prefer more vCPUs.
Review the exact size, image/zone compatibility and costs; do not increase quotas
or silently downsize. See the [global sizing policy](goal/README.md#execution-rules).

Start from the [short project configuration](infra/aws/project.example.json),
authenticate your AWS profile, then review and launch from the checkout:

```bash
./workspace /absolute/path/project.json
./workspace /absolute/path/project.json --authorization 'Approved deployment scope'
```

The first command resolves the account, capacity, repository revision and dataset
into an immutable review. The second launches that reviewed scope. Pinned local
tools install automatically when needed; `./workspace --help` needs no installation.
Use the same config with `status`, `connect`, `logs`, `resume` or `cancel`.
The original `scripts/aws/workspace.sh` command remains compatible.

For repository development, install the separate hash-locked Python 3.13 test
environment, then validate:

```bash
make workspace-test-setup  # package downloads; no cloud account operation
make check                 # complete controller, workspace and provider checks
make historical-check      # explicit preserved batch/demo regression suite
```

The [deployer audit](docs/deployer-audit.md) records fixes and remaining acceptance
limits. Routine tests query no cloud accounts or APIs. Backend-disabled OpenTofu init
may download pinned providers. Offline passing results are not live readiness.
The acceptance example checks tiny `1, 2, 3, 4` bucket fixture values for count 4,
sum 10, mean 2.5 and stable JSON round-trip bytes. Its offline transfers are
simulated; actual upload/authentication is separately reviewed per provider.

| Owner | Scope |
| --- | --- |
| AWS / GCP / Azure | `infra/<provider>/{bootstrap,platform,runner}`, provider scripts/tests and operations guide |
| Shared integration | `shared/workspace/`, `scripts/workspace/`, `tests/workspace/`, repository checks and shared docs |
| Local evidence | Ignored `evidence/`; only layout documentation is tracked |
| External ML repository | Project dependency locks, code, dataset content and durable output choices |

Account setup guides: [AWS](docs/account-setup/aws.md),
[GCP](docs/account-setup/gcp.md), [Azure](docs/account-setup/azure.md).
Existing [architecture](docs/architecture.md), [batch contract](docs/contract.md)
and [batch lifecycle](docs/operations/lifecycle.md) describe historical interfaces
until provider migration. They do not define the new workspace user journey.

Validation is not apply authorization. Cloud apply, destroy, import, state
movement, IAM/billing changes, image publication, data upload and local pruning
each require an exact reviewed scope and explicit authorization. Preserve old
state/evidence and classify existing resources before migration. Workspace
teardown retains persistent workload storage and state storage separately.
