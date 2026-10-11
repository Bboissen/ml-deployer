# AWS controller configuration migration

Baseline: merged `main` at `fd640b69d5018e27b8bdb2f896186a6997777b55`.
[PR24](https://github.com/Bboissen/Ray_terraform/pull/24) demonstrated one bounded
private SSH/Make job, exact S3 object-version verification before and after compute
teardown, and retained storage. Its tiny acceptance result does not establish
generic project, dataset, identity or account support.

Improve the existing Python controller and retain OpenTofu as the infrastructure
owner. Keep one plan/authorization/cleanup implementation. The source milestone
adds configuration preparation; it does not migrate native state or resources.
The older overview checkout and other worktrees retain their changes and evidence.

## Assumption inventory

| Current assumption | Source | Classification and migration |
| --- | --- | --- |
| Account `000000000000` | `workspace-lifecycle.sh`: foundation packet, old storage handoff | Discover account from the explicit temporary profile; current native foundation scope remains restricted until its validators and roots change together |
| Project `demo`, workspace `demo-dev-01` | `workspace-lifecycle.sh`: foundation and packet; `workspace.example.json` | User project/workspace choices; generate canonical names without adopting existing resources |
| Infrastructure prefix, backend bucket, keys, deployment role and policy ARNs | `workspace-target.sh`, `workspace-lifecycle.sh`, `workspace.example.json` | Derive from account, region and project; existing foundation outputs/lineage take precedence only after verified ownership |
| Single reviewed workload bucket | `workspace.sh`: render; `workspace-storage.sh`: preparation | Reuse the existing deterministic bucket naming rule; keep state and workload buckets separate |
| Operator `sposhfi-admin` | runner `terminal.tf`; lifecycle foundation, inventory and terminal checks; E2E document checks | Discover identity; native grants currently support that exact IAM user. Federated role/SSO policies need a separate matched root/validator change |
| `us-east-1`, `us-east-1a` | `workspace.sh`, lifecycle, runner variable validations | Supported deployment profile; region/zone expansion requires image, offerings and quota observations plus matching scope validation |
| `r8i.2xlarge`, 8 CPUs, 60000 MiB usable RAM, 25 GiB disk | `workspace.sh`, lifecycle capacity checks, runner variables | Supported profile; retain RAM-first policy and refresh regional/family quotas before any launch |
| AL2023 AMI, RPM/CLI/SDK pins, host key | guest `toolbox/versions.json`, shared toolbox, `workspace-e2e.py` | Reviewed immutable profile/trust artifacts, never arbitrary user image inputs |
| 15–60 minute lease, one launch, pre-armed deadline/watchdog | `workspace.sh`, lifecycle, runner roots | Safety limits; preserve absolute expiry through partial failures and controller loss |
| Manual output hashes, applied-plan paths and artifact paths | `workspace.example.json`, `workspace.sh`: render | Generate from immutable artifacts and applied outputs in later foundation onboarding; retain compatibility inputs meanwhile |
| SSH-only unattended clone and Make target | `workspace-e2e.py`, `workspace-job.sh` | User repository/ref and explicit setup/run argument arrays; runtime public/private onboarding and execution follow separately |
| Linux `findmnt` and `/dev/shm` during operator key validation | `workspace-e2e.py`: verify_ssh | Host portability gap; Linux and macOS remain first-release installer requirements. Do not replace RAM-only key handling with ordinary disk files |
| Already-uploaded input, whole-object download, 1 MiB limit | `workspace-e2e.py`: preflight/object_bytes | Acceptance-only input verification; ingestion requires immutable streamed manifests before compute |
| Expected result hash, dependency-lock hash and NumPy/pandas provenance | `workspace.sh`, `workspace-e2e.py`: verify_result | Acceptance-only assertions; generic execution must report setup/job/output/cleanup outcomes independently |
| Region-wide zero EC2 with no pagination | `workspace-e2e.py`: preflight | Acceptance-only exclusion; future operations need paginated ownership/capacity checks and workspace locking |

## Ownership and evidence

This milestone performs source changes and offline checks. It makes no fresh
native inventory claim. Existing foundation resources, state lineages, deploy
keys, secret versions and storage remain separately owned; no resource is imported,
recreated, renamed or deleted by configuration preparation. A later resource
migration must first refresh the selected account's ownership/lineage observations
and inspect each exact saved plan against its authorized scope.

The historical acceptance receipt remains under the toolbox worktree's ignored
`evidence/aws/autonomous-training-finalization/` tree. New preparation records
belong under this worktree's ignored `evidence/aws/` root. They are configuration
evidence, not apply authorization or proof of native readiness.
