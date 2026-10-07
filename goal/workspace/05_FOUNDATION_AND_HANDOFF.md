# Shared foundation and provider handoff

This milestone implements offline workspace interface **2.0.0**, a CPU toolbox
profile and a bounded NumPy/pandas acceptance example. Provider launch, terminal,
storage authentication and hard-deadline implementations remain pending. Passing
offline checks is not live acceptance. Stop for foundation review before starting
the three provider tasks.

## Concrete integration baseline

Remote `main`: `2ac1a145400dc515bc6040f39f3e60591ffd11d8`.
PR18: `4ae5f39a4d745ab84b296b9a62c4dad74ab05fd4`.
PR19: `4c658af13014ce7622491b367b59f3cf498a2bbc`, stacked on PR18.
The original dirty checkout remains on `docs/independent-ml-workspace-goals`.
Its diff and hashes of 121 existing files are preserved under its ignored
`evidence/foundation/20261007-shared-foundation/`. No stash or checkout reset
was used. Work happens on `feat/shared-workspace-foundation` in an isolated
worktree based on remote main.

| Source | Integration decision |
| --- | --- |
| Main | Keep provider roots, nine lock files, native storage/identity boundaries, saved-plan authorization and existing batch contracts unchanged. |
| Dirty checkout | Carry the accepted AGENTS, workspace goals and evidence layout into this task; leave unrelated documentation, provider adapter edits and unique untracked content in place. |
| PR18 | Preserve as an open historical branch; do not merge its roughly 5,700-line dummy lifecycle into this milestone. Its immutable input/version discipline informs the acceptance transfer tasks. COS repairs remain relevant only if GCP retains COS. |
| PR19 | Reuse its closed-field/type, exact ID-boundary and fail-closed validation behavior in interface 2.0.0. Backport the compatible 48/49-character batch request regression. Provider request typing, Azure input version and GCP authenticated absence/IAM fixes are explicitly assigned below. |
| Breaking batch change | Do not add `input_object_version` to main's existing `1.0.0` contracts under the same version. Provider owners must reconcile PR18/19's historical variant and immutable artifacts before migration. Never rewrite receipts or accepted-common hashes. |

No provider Terraform resource, backend, state address or launch path is changed.
PR18/19 can remain open; neither is a dependency of workspace foundation review.
If they later merge, the integration owner must reconcile the common files and
rerun both check suites before provider branches rebase.

## One integration owner

The foundation integrator owns `AGENTS.md`, `.gitignore`, `Makefile`,
`README.md`, `evidence/{README.md,.gitignore}`, `goal/README.md`,
`goal/workspace/{00_SCOPE_AND_CLEANUP,01_TOOLBOX_CONTRACT,05_FOUNDATION_AND_HANDOFF,06_CLEANUP_INVENTORY}.md`,
`docs/workspace.md`, `scripts/check-repository.sh`, `scripts/workspace/`,
`shared/workspace/`, `tests/workspace/`, and the existing shared contracts,
bootstrap, conformance and dummy dispatch files during migration. Provider
branches consume these files; propose changes to the integrator rather than
editing them concurrently. No shared resource, registry or orchestration service
is introduced. Cross-cloud acceptance aggregation is unnecessary.

| Provider owner | Exclusive implementation paths |
| --- | --- |
| AWS | `infra/aws/`, `scripts/aws/`, `tests/aws/`, `docs/operations/aws-workspace.md`, `goal/workspace/02_AWS.md` |
| GCP | `infra/gcp/`, `scripts/gcp/`, `tests/gcp/`, `docs/operations/gcp-workspace.md`, `goal/workspace/03_GCP.md` |
| Azure | `infra/azure/`, `scripts/azure/`, `tests/azure/`, `docs/operations/azure-workspace.md`, `goal/workspace/04_AZURE.md` |

Each owner creates its own worktree, `feat/<provider>-workspace` branch and focused
PR from the merged foundation commit. Keep `runner` root names and their existing
state lineage. Split subsequent broad work at each provider goal's review gates.
Do not merge other provider branches as dependencies. Integrator registration in
the default check target is sequential after a provider adapter is ready.

## Independent task prompts

**AWS:** Work in an isolated branch from the merged foundation. Read AGENTS,
the existing reconciled audit, this handoff, the cleanup inventory, interface
2.0.0 and `02_AWS.md`. Implement only AWS-owned workspace paths. Reconcile main
and PR18/19 AWS input-version/request-type fixes before changing historical
interfaces. Prepare resource disposition first. Provide generic S3 handoff,
non-root clone-ready EC2 toolbox, named Session Manager access, narrowed SSM
parameter permissions and a provider-side guard active before compute. Prove
IAM ordering and partial-apply bounds offline; emit and validate the three 2.0.0
records. Keep data/state persistent and separate. Add AWS-only native transfers
for the bounded acceptance example. Stop at a reviewed source/plan milestone;
no apply, IAM change, upload, image publication or destroy is authorized.

**GCP:** Work in an isolated branch from the merged foundation. Read the same
shared files and `03_GCP.md`. Implement only GCP-owned workspace paths. Prepare
disposition of the two surviving dummy states/jobs/identities and old storage
first. Selectively retain PR18/19 authoritative absence, keyless generation and
IAM tests; avoid their dummy paths/publisher/registry requirements. Provide
native GCS handoff, a supported Linux toolbox, named IAP/OS Login access and
creation-time VM duration protection. Emit and validate interface 2.0.0 records;
add GCP-only native transfers for the bounded example. Test inherited IAM,
partial failures and storage retention offline. Stop for source/plan review;
no cloud mutation, import, state move, publication, upload or destroy is authorized.

**Azure:** Work in an isolated branch from the merged foundation. Read the same
shared files and `04_AZURE.md`. Implement only Azure-owned workspace paths.
Reconcile PR19's request-type/input-version fixes without relabelling batch
evidence. Before dependent launch work, obtain review of the exact interactive
access route/cost and independent absolute lifetime guard covering partial apply.
Provide native Blob handoff, scoped managed identity, non-root Linux toolbox and
truthful deallocation/deletion/billing evidence. Emit and validate interface
2.0.0 records; add Azure-only native transfers for the bounded example. Keep
unsupported access/deadline paths closed. Stop for source/plan review; no role
change, provider registration, apply, upload, publication or destroy is authorized.

## Decisions and acceptance still outstanding

Azure access route and AWS/Azure pre-compute guards require concrete provider
design review. Exact image/bootstrap pins and provider CLI/SDK pins belong to each
provider, not an assumed common image. Named operators, scopes, resource sizes,
data prefixes and export destination are supplied at those reviews. The Gold
dataset remains absent. The cleanup inventory is a proposal, not authorization.
Historical AWS login/current resources and GCP drift must be refreshed by their
owners; this milestone deliberately reuses the audit instead of repeating it.
