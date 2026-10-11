# AWS automation implementation handoff

Historical planning snapshot. The installer/configuration/onboarding/ingestion/job/deploy
stack is now consolidated; use the [current quickstart](../../docs/operations/aws-deployer-quickstart.md)
and [native acceptance checklist](../../docs/operations/aws-native-acceptance.md)
for current commands and remaining acceptance. PR27–34 references below describe
the earlier implementation milestones.

Implement the [AWS automation goals](07_AWS_AUTOMATION.md) one milestone at a
time. PR24 is merged; draft PR27 adds short configuration and draft PR28 adds
workstation installation/assisted login. Verify their current branch/merge state
and reuse that source before continuing. The next source task is M3 foundation
and repository onboarding with the unfinished M1 identity/discovery work. No
replacement infrastructure stack or controller rewrite is needed.

## Context that must survive handoff

- The original overview checkout at `4ae5f39` is behind merged workspace work.
  Preserve its dirty tree. Use an isolated task worktree from current main.
- At audit time main was `fd640b69d5018e27b8bdb2f896186a6997777b55`.
  PR24 source `4ea7ab0` has a successful native SSH/Make/S3/cleanup receipt.
  The acceptance fixture is not proof of generic data or project support.
- The active controller is `scripts/aws/workspace.sh` with
  `scripts/aws/workspace-e2e.py` and `workspace-lifecycle.sh`. Several shell
  entrypoints embed Python. Reuse their plan/authorization/guard behavior.
- Keep AWS workspace bootstrap, platform and runner ownership separate. Reuse
  retained resources only after identity/state/receipt checks; never recreate
  a foundation from historical plans or remove evidence to clear an error.
- New configuration must generate technical details, not just move the same
  long list of ARNs, hashes and paths into a different form.
- The user's desired product is one Deploy action after guided setup, with
  provider, local/distant dataset source, repo/ref, Make target or entrypoint,
  names, resource profile and bounded lifetime. AWS is first; GCP/Azure remain
  explicit unsupported capabilities until their own implementations are accepted.
- The user explicitly selected automatic dependency installation and entrypoint
  execution on every Deploy. Linux and macOS must both be supported in the first
  installer release. Do not ask these two questions again.
- First-release dataset sources are also decided: local files/directories, S3
  and public HTTPS. Private remote source services and cross-cloud transfers
  remain deferred.
- Keep the Python engine and Bash workstation bootstrap. PR27 source at
  `4622a05` prepares immutable configuration operations but deliberately rejects
  generic execution; PR28 at `d430823` installs tools and assists login. Their
  clean Linux installation does not establish native macOS or complete Deploy
  acceptance. The interactive HTML checklist is personal notes, not authorization.

## Next implementation deliverable

1. Read `AGENTS.md`, `goal/README.md`, the
   [audit](../../docs/aws-automation-feasibility.md) and the current controller
   before editing. Confirm current main/PR status without overwriting other work.
2. Reuse PR27's assumption inventory, schema and resolved deployment records.
   Generalize account/project/operator bindings together in roots and their
   scope validators. Keep supported profiles explicit and preserve existing
   explicit configuration as a compatibility route until new acceptance.
3. Prepare bootstrap/platform/access plans from resolved intent, capture actual
   outputs automatically and verify existing identity, ownership, state lineage
   and guard artifacts before reuse. Remove manual copying of ARNs/hashes and
   applied-output paths; a matching name alone never permits adoption.
4. Reuse the private read-only deploy-key route. Register it only with authorized
   repository-owner access, store private material outside OpenTofu plans/state,
   and add portable RAM-backed key handling. Public HTTPS needs no credential.
   Login success alone never establishes VM access or supported SSO grants.
5. Add meaningful offline checks for different account/project/operator scopes,
   missing grants, unrelated resources and interrupted onboarding. Source work
   implies no cloud mutation, key registration, credential change or data transfer.
   Record the exact remaining native acceptance; proceed to M4/M5 afterward.
6. Deliver one branch/PR with Summary, Tests run and Risk / rollback notes.
   Stage only task paths; preserve state/evidence and other uncommitted changes.

## Required boundaries for later tasks

The installer handles local tooling and guides login; it never provisions AWS
infrastructure as a hidden installation side effect. Account creation, MFA,
billing and organization grants are owner actions. No IAM access keys are created.

Deploy carries one bounded task authorization. Each root's exact saved plan is
still inspected, hashed and recorded before apply. Routine stages inside the
scope proceed automatically. Stop only for a material scope, permission, cost or
destructive expansion. Separate stages do not imply repeated user prompts.

Ingest bytes before compute, seal native object versions and reject unsupported
source schemes. Do not put production data into source or evidence archives.
Run the external repo's selected commands as non-root; never discover its Make
targets by running untrusted code on the operator workstation.

Keep deterministic acceptance output assertions outside generic production
success. Record execution, output persistence and cleanup separately. Preserve
the pre-armed provider guard through failures and report residual paid resources.
Do not retry an uncertain launch until exact owned resources are reconciled.

## Evidence and completion

Historical successful receipt on the audit host:
`/home/user/docker/Ray_terraform-aws-toolbox-lifetime/evidence/aws/autonomous-training-finalization/native-e2e-20261009T212720670778Z/run/result.json`.
This location is provenance for this audit, never a path to hardcode into the
product. Keep new operational material under the active worktree's ignored
`evidence/` root. A clean checkout must be able to generate its own configuration
and evidence rather than requiring that author's receipt directory.

Finish the migration when a user on a clean supported host can authenticate,
choose a dataset/repo/profile, review once, deploy, obtain durable output and
verify teardown, then repeat using retained data without manual ARN/hash/state
editing. Record any unsupported identities, platforms, datasets or cloud providers
explicitly; do not advertise generic acceptance from the tiny fixture alone.

After every test, remove exact task-owned containers, images, volumes, provider
copies, extracted downloads, caches, temporary runtimes and scratch payloads,
including after failure/interruption. Keep small logs/receipts, record and verify
cleanup, preserve unrelated/user-installed resources and real state/evidence,
and never use global Docker/cache pruning.
