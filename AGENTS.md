# AGENTS.md

## Priorities

- **Autonomous Git:** one task/branch/PR. Open a draft early; commit/push tested milestones and update the PR continuously. No routine permission requests; merge only when authorized.
- **Simplicity:** smallest complete solution. No speculative features, rewrites, thin wrappers or unnecessary abstractions.
- **Mandatory reuse:** reuse existing code; factor duplicated logic into focused functions/modules. Separate providers; share only equivalent behavior.
- **Security:** least privilege, temporary native cloud identities, private encrypted storage, non-root execution. Validate inputs, use safe argument passing, verify downloads, redact secrets. No static cloud keys or secrets in source/bootstrap/plans/state/logs.

## Boundaries

- Follow `goal/README.md`. Infrastructure only; external repos own ML/dependencies/data. Bounded acceptance examples are allowed; dataset integration requires authorization.
- Continue within authorized scope; clarify material ambiguity or expanded account/cost/destruction. Source-only stays source-only. No subagents unless requested.
- Use `rtk`; report milestones and bounded monitoring, not continuous polling.
- Preserve unrelated work and resource ownership. Keep state/backups/plans/authorizations/receipts in ignored `evidence/`; track only layout docs. Deletion needs exact authorization and verified receipt. No permanent `legacy/`.
- Separate provider bootstrap/platform/runner roots and state/workload storage. Configure providers only in roots; keep composition flat. Pin OpenTofu/providers and commit lockfiles.
- Inspect immutable saved plans; bind scope/hash to existing task authorization before apply. No repeated prompts.
- Require provider-side maximum lifetime covering partial failures; budget alerts are insufficient. Run relevant checks; routine tests stay offline/mocked.

## Git hygiene

- Use `feat/`, `fix/`, `refactor/`, `docs/`; never commit on `main`/`master` or use `codex/`. Isolate unrelated work.
- Stage explicit paths; never `git add .` or `git add -A`.
- Before committing: `git status --short`, `git diff --stat`, `git diff --cached --stat`.
- Small reviewable diffs. PR bodies: Summary, Tests run, Risk / rollback notes.
