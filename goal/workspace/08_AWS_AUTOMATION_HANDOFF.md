# AWS automation implementation handoff

Implement the [AWS automation goals](07_AWS_AUTOMATION.md) one milestone at a
time, starting from current merged `main` containing PR24. The immediate task is
M0/M1 source reconciliation and the short user configuration, not another tiny
native acceptance run or a replacement infrastructure stack.

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

## First implementation deliverable

1. Read `AGENTS.md`, `goal/README.md`, the
   [audit](../../docs/aws-automation-feasibility.md) and the current controller
   before editing. Confirm current main/PR status without overwriting other work.
2. Inventory hardcoded assumptions in configuration, foundation creation,
   terminal grants, launch IAM, VM variables, preflight and result verification.
   Classify user choice versus discoverable value versus supported profile.
3. Propose the versioned short configuration and resolved deployment document.
   Generate a review summary and stable names offline. Track how discovered
   outputs and immutable artifacts populate internal fields. Preserve the old
   explicit configuration as a compatibility route until new acceptance.
4. Implement job mode as the default, including declared setup and execution.
   Plan Linux and macOS installation and verification in the first release.
   Keep other follow-up choices in the goal decision table; clarify only where
   they materially affect the next implementation scope.
5. Implement the smallest M1 slice with meaningful positive/negative validation.
   No cloud mutation is implied by this planning handoff. Use read-only discovery
   where relevant and record which facts remain unknown.
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
