# AWS automated deployment goals

Status: updated 10 October 2026 from merged `main` at `fd640b6` and draft
[PR27](https://github.com/Bboissen/Ray_terraform/pull/27) (`4622a05`) /
[PR28](https://github.com/Bboissen/Ray_terraform/pull/28) (`d430823`). AWS has a
successful bounded SSH/Make native run. Short configuration and workstation
tools/login have source milestones; generic deployment remains incomplete.
These goals authorize source work, not new cloud mutations, credential changes
or data upload.

The user supplies a provider, dataset source, GitHub repository/ref, explicit
entrypoint and friendly names. The software installs supported local tools,
guides authentication, discovers technical configuration, presents a bounded
deployment scope and executes its stages from one Deploy action. AWS comes first;
the interface leaves native GCP and Azure adapters possible.

See the [feasibility audit](../../docs/aws-automation-feasibility.md),
[setup guide](../../docs/aws-setup-guide.html) and
[handoff](08_AWS_AUTOMATION_HANDOFF.md).

## Current implementation and next work

| Milestone | Current evidence | Remaining |
| --- | --- | --- |
| M0 | Baseline and hardcoded-assumption inventory recorded in PR27 | Refresh native ownership before any resource migration |
| M1 | Short JSON schema, account/revision discovery, deterministic names, local dataset metadata and immutable configure/status records | Foundation/capacity/price discovery, generalized operator scope and deployment from those records |
| M2 | PR28 Bash installer, pinned tools, console/SSO/GitHub login assistants; clean Linux x86_64 installation and offline checks | Native macOS/arm64, Linux arm64 and real browser-login acceptance; backend/provider checks in onboarding |
| M3 | Existing roots and private SSH credential route to reuse | Next source task: generalized foundation/access plans, automatic output capture and scoped deploy-key registration |
| M4 | Confirmed first-release sources: local files/directories, S3 and public HTTPS | Streamed/versioned ingestion, source-change checks and safe reuse before compute |
| M5 | Existing bounded private clone/Make/S3 lifecycle proven | Generic explicit setup/run commands, declared output persistence and separate outcomes |
| M6 | Saved-plan inspection, task authorization, expiry and owned cleanup engine exists | One Deploy from short config, durable journal, locking and reconciled recovery |
| M7 | Clean Linux installer and earlier bounded AWS job accepted separately | Full clean-host Linux/macOS journey, repeated data reuse and versioned release artifacts |

Keep Python for orchestration, Bash for first installation and OpenTofu for
infrastructure. No rewrite is needed. The interactive guide tracks personal
setup TODOs only; checked boxes never establish runtime readiness or authorization.

## Product contract

- First use includes browser authentication and any account/repository owner
  grants. Returning use with valid credentials should need only the project
  choices and Deploy. The current task authorization can cover all routine
  stages inside one concrete scope; do not add per-stage approval prompts.
- Generate account bindings, names, ARNs, state keys, output hashes, versions,
  artifact locations and per-operation evidence paths. Do not ask users to
  hand-edit generated OpenTofu files or carry opaque hashes between commands.
- Deploy defaults to `job` mode: install the repository's declared dependencies
  and execute the selected entrypoint every time, then preserve declared outputs
  and remove owned compute. This is the user's explicit choice. Optional
  `workspace` mode is an advanced route that stays available until teardown or
  the absolute lease. Linux and macOS are both required in the first release;
  Windows is deferred.
- Keep RAM-first sizing from the accepted goals. Discover supported capacity,
  rank within remaining quota and show the selected SKU and estimated costs.
  A user-selected price ceiling can further constrain the candidates; do not
  silently impose another default or treat quota as a spending limit.
- Provision empty native storage first. An explicitly selected transfer may
  follow in the same operation. Reuse data on subsequent deployments. Gold
  content, transformations and production ML stay with the external project.
- Preserve the proven pre-launch guard, least privilege, non-root execution,
  exact saved-plan validation and immutable evidence under `evidence/`.
- Keep persistent state and workload storage separate. Automatic job cleanup
  removes only that operation's disposable resources. Existing resources are
  reused only with verified ownership; no implicit import, pruning or deletion.

## Proposed user configuration

The example below is the original design sketch. PR27 now publishes a closed
JSON project schema 1.0.0 and a concrete example; use that draft's example rather
than passing this YAML to the CLI. Short configs currently support `configure`
and `status` only, with `execution_supported: false`.

```yaml
version: 1
provider: aws
target: personal
project: demand-forecast
workspace: experiment-01
region: us-east-1
dataset:
  source: /home/user/datasets/demand
  destination: auto
repository:
  url: https://github.com/owner/project.git
  ref: main
mode: job
commands:
  setup: [make, setup]
  run: [make, train]
outputs:
  paths: [outputs]
resources:
  policy: ram-first
maximum_runtime_minutes: 60
```

The local path is resolved on the controller host. `ref` resolves to one commit
before authorization/execution. `commands` belong to the external repository;
the configurator does not execute them to guess dependencies. In job mode the
scope includes those commands and normal disposable-resource cleanup. In
workspace mode automatic project execution is absent unless explicitly selected.
Authenticated repository/source details are credential references, never tokens
in the user configuration. The output policy selects either explicit local
paths to persist or project-managed native writes, with separately defined checks.

## Migration sequence

Each milestone is one reviewable task/branch/PR. Dependencies are sequential;
source and mocked checks precede any separately authorized native acceptance.

### M0 Establish the current baseline

Base implementation on merged `main`, not the older dirty overview checkout.
Retain its uncommitted work and all worktree evidence. Record the successful
PR24 run and its limitations. Correct stale status prose, and inventory every
hardcoded account, project, operator, zone, SKU, image and acceptance-only rule.
Do not re-create the deployed foundation or import old batch states.

Acceptance: an inventory maps each constant to a user choice, discovered value,
supported profile or acceptance-only fixture. The existing bounded job still
passes offline tests. Native state ownership has an explicit read-only record
before implementation proposes any resource migration.

### M1 Version the user configuration and discovery result

Introduce one small user configuration, a fully resolved deployment document
and a local operation registry. Reuse shared workspace 2.0 where semantics fit;
version changes explicitly without relabeling historical artifacts.

Discover account/identity from the chosen profile, regions/quotas/compatible
images and offerings, and existing retained foundation outputs. Derive
deterministic names and backend keys. Resolve Git refs, normalize local paths,
count selected data bytes and reject unsupported schemes before spending.
Prefer a supported-profile catalog over arbitrary machine/image inputs.

Generalize scope validators together with the resources they protect. Replace
the named IAM-user terminal policy with explicit supported user/role paths;
SSO cannot be accepted merely because STS succeeded. Support multiple projects
without widening one workspace's access to other data or state.

Acceptance: two different project/account configurations render without source
edits; unknown fields, source paths, identity mismatch, collisions and mixed
regions fail clearly. Generated fields trace to inputs/provider observations.
Do not claim a second account has native acceptance from mocked rendering.

### M2 Deliver the workstation installer and setup guide

Provide a pinned, repeatable Linux and macOS installer with check-only mode,
declared supported OS/architecture matrix, verified downloads and a user-owned
installation prefix
where supported. Install only required tools; preserve existing profiles,
credential stores and shell startup files. Give exact repair instructions for
unsupported host/privilege conditions. RTK is optional for end users.

Add assisted `aws login`/SSO and optional GitHub login. Generate non-secret
profiles/configuration and detect missing permission or expired sessions. Check
CLI, SDK, backend and OpenTofu identity consistently. The guide maps each real
user field to discovery or its official console location; internal ARNs and
hashes are implementation output, not required user homework.

Acceptance: clean supported Linux and macOS host installation, rerun with no
destructive changes, wrong hash/signature, unsupported architecture, missing privileges,
expired login and conflicting installed tools. No secrets in installer logs,
HTML, generated configuration, plans or evidence. Browser consent remains human.

### M3 Automate foundation and private repository onboarding

Drive bootstrap and persistent platform sequentially through existing roots.
Create only the selected owned resources; reuse the existing foundation after
identity, lineage, guard and artifact verification. Generate all dependency
paths and capture actual outputs. Offer one readable scope with anticipated
retained resources and costs; inspect each later exact plan before apply.

Support public HTTPS cloning without credentials. For private GitHub, automate
registration of a read-only deploy key and its secret reference only when the
operator has repository and secret-management rights and has authorized those
objects. Preserve rotation/revocation ownership. No private key in OpenTofu
inputs/state. Keep GitHub App tokens as a later optional authentication adapter.

Acceptance: no manual copying of foundation hashes, bucket names, secret versions
or role ARNs; interrupted setup resumes by observing state; existing unowned
resources and missing grants stop before compute. A scoped operator works without
relying on an administrator's extra policies. Confirm alarm delivery where the
chosen transport requires owner subscription confirmation.

### M4 Add dataset ingestion and reuse

Implement local file/directory, same-provider S3 object/prefix and public HTTPS
file support. Use explicit source adapters. Private HTTP, SSH/SFTP and cross-cloud
sources remain unsupported until separately accepted. Determine transfer scope,
destination, size limit, overwrite/reuse behavior and fees before starting.

Upload before compute; use versioned immutable dataset manifests containing
object paths, bytes, checksums and native versions. Stream large inputs and
bounded multipart transfers. Resume only verified completed objects or recorded
parts; a CLI sync rerun alone is not a multipart-resume guarantee. Detect changed
source files and do not silently accept a mixed snapshot. Reuse exact data
versions; do not delete unrelated destination objects or follow symlinks outside
the selected local tree. Preserve manifest and transfer evidence.

Acceptance: empty input, multi-file trees, spaces, symlinks, changed source,
duplicate names, restricted source, expired URL, checksum mismatch and interrupted
multipart upload. Native acceptance includes a non-sensitive file larger than
the old 1 MiB bound, bucket reuse and a failed transfer that launches no compute.
Do not use or upload production Gold for these tests.

### M5 Generalize project execution and outcomes

Reuse the non-root checkout, exact revision, cleared environment and credential
removal. Add explicit setup/run argument arrays and public HTTPS to unattended
execution. Declare a supported toolbox profile; arbitrary dependencies may
fail and must report a project setup error without privileged auto-repair.

Replace fixture-specific mandatory result hashes with execution status and
durable artifact metadata. Keep expected hashes/count/sum/mean only in the tiny
acceptance profile. Preserve optional project checks without grading ML results.
Record `infrastructure_ready`, `setup_exit`, `job_exit`, `outputs_persisted` and
`cleanup_status` separately. Collect bounded logs and declared outputs; no claim
of automatic checkpoint safety beyond the configured transfer policy.

Acceptance: two ordinary small repos with different Make targets or executable
entrypoints work without infrastructure source edits or pre-known result hashes.
Include setup failure, nonzero exit, output-copy failure, timeout and a fresh
run that cannot pass using another run's outputs. Interactive mode must retain
the workspace after setup and preserve the absolute expiry.

### M6 Compose one Deploy action and recoverable operation status

Expose one top-level CLI wizard/command using the existing engine. Its scope
includes the selected foundation changes, transfer, access, one launch, execution
and cleanup policy. Write exact saved-plan checks and authorization receipts
automatically under that task scope. Unknown additions, replacements, deletion
of persistent resources or cost/profile expansion require a new decision.

Add a durable stage journal and bounded `status`, `logs`, `connect`, `cancel`
and `resume` operations. Reconcile remote state and owned resources after
process termination; preserve independent expiry if the controller disappears.
Replace region-wide zero-EC2 acceptance with paginated ownership and capacity
checks. Exclude concurrent mutation of the same workspace and make retries
operation-aware. Keep cloud and source errors actionable rather than retrying
launches blindly. A static HTML guide is sufficient initially; a local browser
button is a separate frontend to this same operation API.

Acceptance: deployment from short config without manual generated-file edits;
no repeated routine authorization prompts; loss of terminal/network, stale
session, partial apply, SIGKILL and repeated Deploy cannot create a duplicate
VM or disable its guard. Provider failures report known/unknown states, preserve
evidence and leave an exact recovery instruction.

### M7 Accept the full AWS journey and distribute it

From clean supported Linux and macOS workstations: install, authenticate,
configure, select a local dataset and external repo, review once, deploy, inspect outputs and prove
runner teardown with retained storage. Repeat against the same data. Exercise
public and private repo paths and the supported remote dataset source. Record
which operator identities and profiles have native acceptance.

Run meaningful offline suites by default. Add CI for supported installer/config
paths and existing infrastructure policy tests, then versioned release artifacts
with integrity metadata. A deliberate, bounded native campaign covers failures
where feasible; do not equate mocked failure tests with live fault acceptance.

Acceptance: reproducible quickstart, versioned artifacts, known limitations,
native happy-path evidence and named failure coverage. Readiness must not depend
on the author's absolute local paths, credentials or undocumented receipts.

### M8 Add optional hosted execution and other clouds

After AWS acceptance, optionally expose GitHub workflow dispatch using OIDC and
exact repo/environment trust. Stage local datasets before dispatch. Protect
deployment mutations from untrusted PR code; do not put privileged cloud access
in arbitrary model-repository workflows by default. Keep private ML-repo auth
separate from AWS federation. This milestone is not required for local one-click.

Implement GCP and Azure adapters independently against the same intent/result
contract. Use native storage, identities, terminal routes and runtime safeguards.
Provider capability checks fail before mutation when unsupported. No resource
roots, credentials, active orchestration or acceptance runs span clouds.

Acceptance: mocked adapters preserve the common contract; each provider later
passes its own native deployment/storage/access/expiry/teardown acceptance.

## Decisions to settle before the dependent milestone

| Decision | Recommended starting point | Needed before |
| --- | --- | --- |
| Default Deploy mode | Decided: install declared dependencies and run selected entrypoint automatically every time | M1 user interface |
| Installer platforms | Decided: Linux and macOS in the first release; declare tested distro/architecture versions | M2 implementation |
| Meaning of distant dataset | Decided: local files/directories, S3 and public HTTPS first; private sources deferred | M4 scope |
| Private Git route | Reuse scoped deploy keys; add GitHub App if ongoing needs justify it | M3 credential setup |
| Browser deployment | CLI wizard and HTML guide first; optional local controller UI later | M6 UI |
| Cost preference | Retain RAM-first; offer an explicit user-selected price ceiling | M1 sizing UX |

Rows marked decided record the user's answers. Other rows are proposed scope choices.
Do independent work first and ask only before a decision changes implementation,
cost or access. No architecture rewrite is needed to finish the AWS-first path.
