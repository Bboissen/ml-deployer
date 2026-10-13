# Independent cloud ML workspaces

This repository creates an ML-ready machine, persistent native object storage,
toolbox, authenticated terminal access and bounded lifetime on AWS, Google Cloud
or Azure. Each provider operates independently. The user connects, clones an
external ML repository and installs its project dependencies; that repository
owns scripts, datasets, transformations, training and results.

## Quick start (AWS)

```bash
git clone https://github.com/Bboissen/Ray_terraform.git
cd Ray_terraform
make            # or ./workspace guide when make is not installed
```

`make` installs the pinned tools into the ignored `.tools/` folder, checks what
is already done and opens the [first-use guide](docs/aws-setup-guide.html) in
your browser with every step marked done or to do, plus the exact next command.
It never logs in, deploys or changes cloud resources. Do the next step, run
`make` again, and repeat until Deploy.

Shared foundation **2.0.0** is implemented offline. A bounded private SSH/Make job,
versioned S3 verification and compute teardown passed native acceptance in
[PR24](https://github.com/Bboissen/Ray_terraform/pull/24). That AWS foundation was
removed on 13 October 2026 for a from-scratch run; the next Deploy recreates it.
The AWS deployer now implements short configuration, scoped foundation/access
onboarding, streamed local/S3/public HTTPS ingestion, generic non-root setup/run,
declared output persistence and one reviewed Deploy with durable recovery.
See the [deployer quickstart](docs/operations/aws-deployer-quickstart.md),
[operation and recovery behavior](docs/operations/aws-deploy-operation.md) and
[native acceptance scope](docs/operations/aws-native-acceptance.md).

The repository is a release candidate (`0.1.0-rc.1`) for a clean installation,
with native generic acceptance still pending: a real generic job with durable
outputs, clean macOS/arm64 installation with browser login, real IAM/alarm
behavior and controller-loss drills. Offline mocked suites and a clean Ubuntu
container install without preinstalled Python pass. The earlier native fixture
receipt does not establish the complete generic journey, and no release is
published yet.
Google Cloud and Azure workspace implementation remain pending. Existing
batch roots, contracts and historical evidence remain preserved during migration.
No cross-cloud service, registry mirror, homelab, local VM or Ray cluster is needed.

Start with `make` and the [first-use guide](docs/aws-setup-guide.html); the
[deployer quickstart](docs/operations/aws-deployer-quickstart.md) lists the same
commands on one page. [CONTRIBUTING.md](CONTRIBUTING.md) covers development
setup, the pending license decision and releases.

Read the [workspace interface and validation guide](docs/workspace.md),
[goals](goal/README.md), [baseline and independent provider prompts](goal/workspace/05_FOUNDATION_AND_HANDOFF.md)
and [cleanup inventory for review](goal/workspace/06_CLEANUP_INVENTORY.md).

All providers default to the supported CPU machine with the most RAM within the
selected account's remaining regional/family quotas, then prefer more vCPUs.
Review the exact size, image/zone compatibility and costs; do not increase quotas
or silently downsize. See the [global sizing policy](goal/README.md#execution-rules).

Install, sign in, copy the [short project configuration](infra/aws/project.example.json),
check readiness, then review and Deploy from the checkout:

```bash
./workspace setup                                   # pinned local tools; no login, no cloud calls
./workspace login --profile my-workspace --region us-east-1
./workspace doctor /path/project.json               # Ready / Action needed / Unknown with the next command
./workspace /path/project.json                      # readable scope, one confirmation, then Deploy
./workspace /path/project.json status --wait 30
```

Deploy resolves the account, capacity, repository revision and dataset into an
immutable review and asks once; `--authorization TEXT` replaces the prompt for
automation. `./workspace --help` and `doctor` need no installation. Use the same
config with `logs`, `connect`, `resume` or `cancel`; `./workspace setup --fresh`
rebuilds the tools without touching logins, configuration or evidence. The
original `scripts/aws/workspace.sh` command remains compatible.

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
