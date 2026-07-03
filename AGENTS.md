# AGENTS.md

## Mission

Build and maintain an infrastructure repository that provisions temporary Ray workers for ML training and hyperparameter search. The home server is the Ray head. Local VMs and DigitalOcean Droplets are disposable workers.

## Required first reading

Before editing, read:

1. `GOAL.md`
2. `PLANS.md`
3. `docs/architecture.md`
4. `docs/security.md`
5. `docs/runbook-local-lab.md`
6. `docs/runbook-digitalocean.md`

## Non-negotiable constraints

- Never commit secrets.
- Never commit Terraform state.
- Never expose Ray ports publicly.
- Never assume the DigitalOcean cluster can stay running after a test. Every workflow must have a destroy path.
- Prefer small, verifiable changes over heroic rewrites.
- Keep local VM lab working before modifying DigitalOcean automation.
- Use Tailscale for Ray network communication.
- Workers are disposable and must be reproducible from cloud-init or local VM bootstrap scripts.
- All scripts must fail fast with clear errors.

## Verification policy

After changes, run the smallest applicable checks:

```bash
make lint-shell
make python-check
make dryrun
```

If touching local VM bootstrap:

```bash
make local-lab-up WORKER_COUNT=1
make ray-status
make smoke
make local-lab-down
```

If touching DigitalOcean Terraform:

```bash
make do-init
make do-validate
make do-plan WORKER_COUNT=1
```

Only run `make do-up` when explicitly authorized.

## Git policy

- Work on a feature branch for repo changes unless the user explicitly asks to commit on `main`.
- Check `git status --short --branch` before staging.
- Stage only the files that belong to the current task.
- Do not commit generated runtime files, `.env`, Terraform state, `terraform.tfvars`, keys, data, models, or artifacts.
- Before committing, run the smallest relevant local `make` checks from the verification policy.
- Use clear commit messages that describe the operational change, for example `infra: load env for terraform commands`.

## Result-review loop

Ray Tune jobs must write live metrics to:

```text
artifacts/live/trial_events.jsonl
artifacts/live/latest_summary.md
```

Subagents should inspect `latest_summary.md`, compare against the experiment goal, and write notes to:

```text
artifacts/reviews/
```

Do not block training while waiting for review. Treat reviews as asynchronous feedback.
