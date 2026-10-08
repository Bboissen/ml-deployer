# AGENTS.md

## Project boundary

- This repository provisions ML-ready infrastructure on AWS, Google Cloud, and Azure with OpenTofu.
- It does not own model code, training logic, experiment parameters, data transformations, or result analysis.
- DigitalOcean, Ray cluster orchestration, Spotify-specific code, and local ML execution are out of scope.
- The target is an independent cloud workspace with persistent native object storage and a clone-ready toolbox; `goal/README.md` defines the migration goals.
- The external ML repository owns its dependencies and scripts. A pinned OCI workload image and opaque run specification are historical batch interfaces, not mandatory workspace inputs.
- A small locked deterministic data-science example is allowed for toolbox/storage acceptance; production ML remains outside this repository.
- The Gold dataset is not present yet. Provider storage must be generic and empty until a later reviewed integration.

## Working rules

- Do not spawn subagents unless the user explicitly asks.
- Do not resolve material ambiguity yourself; stop and ask.
- On broad or long-running work, provide reviewable evidence at important milestones and continue within the user's authorized scope without repeated approval requests.
- On a long-running script, report only success or failure and create a bounded monitoring command or script instead of continuously polling.
- Prefer the smallest implementation that satisfies the accepted cross-cloud contract.
- Keep provider implementations separate. Share contracts, templates, validation, and documentation only where semantics are genuinely equivalent.

## Cloud safety

- Read-only account, quota, inventory, and plan checks are allowed when relevant.
- Use the user's task instruction as authorization for the cloud actions it reasonably entails. Inspect and record each exact mutation scope before execution; do not request separate approval for every plan or routine step within that scope.
- Stop and ask when an action materially expands the authorized scope, account, cost commitment, or destructive effect. A source-only request remains source-only.
- Preserve local state, state backups, plans, authorization ledgers, receipts, and evidence unless their exact deletion is separately authorized.
- Local state, plans, receipts, authorization ledgers, and evidence belong under the repository-local, Git-ignored `evidence/` root. Keep only its layout documentation tracked. Remove obsolete or rebuildable material only through an explicitly reviewed cleanup with a verified migration/pruning receipt.
- Do not create a permanent `legacy/` tree inside this repository.
- Do not silently orphan or destroy existing resources during the pivot. Record whether each resource will be adopted or decommissioned.
- State storage and workload storage are separate resources.
- Workload identities use temporary/provider-native credentials. Do not create long-lived access keys or embed secrets in OpenTofu, cloud-init, plans, state, examples, or documentation.
- Cost controls must include a provider-side maximum-runtime safeguard. Budget alerts alone are not a hard spending cap.

## OpenTofu

- Use separate provider-specific roots for state bootstrap, the persistent platform, and the disposable runner.
- Root modules own provider configuration. Reusable modules must not configure providers.
- Keep module composition flat and avoid thin wrappers around individual resources.
- Pin OpenTofu and provider versions and commit each root's dependency lock file.
- Routine tests must use validation, plan mode, or mocked providers. Tests must not create real infrastructure by default.
- Saved plans are immutable review artifacts. Inspect the exact plan before applying it, bind it to the accepted task scope and record the user's task authorization without requiring another confirmation.

## Git

- Keep diffs small, reviewable, and human-readable.
- One task equals one branch and one pull request unless the user explicitly asks otherwise.
- Never commit directly to `main` or `master`.
- Do not use `codex` as a branch prefix; use an industry-standard prefix.
- Never use `git add .` or `git add -A`; stage files explicitly by path.
- Before any commit, show `git status --short`, `git diff --stat`, and `git diff --cached --stat`.
- Prefer one small logical commit. Split broad work into separately reviewable tasks and milestones.
- Pull request bodies must include Summary, Tests run, and Risk / rollback notes.
