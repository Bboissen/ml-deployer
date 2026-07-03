/goal Build this repository from scratch into a deployable ML-oriented Ray worker infrastructure without stopping until the local VM lab passes and the DigitalOcean Terraform plan validates.

Outcome:
Create an infrastructure repo that lets my Ubuntu home server act as the Ray head/orchestrator and lets disposable Ubuntu workers join over Tailscale. It must support a local 3-VM lab first, then a DigitalOcean worker smoke test, then a 10-worker DigitalOcean burst.

Verification surface:
Run and pass these commands, in order:

```bash
cp .env.example .env
# edit .env with local Tailscale, Ray, and DigitalOcean values
make venv
make python-check
make lint-shell
make dryrun
make install-head
make head-start
make local-lab-up WORKER_COUNT=3
make ray-status EXPECTED_WORKERS=3
make smoke EXPECTED_WORKERS=3
make tune-synth
make watch-once
make local-lab-down
make do-init
make do-validate
make do-plan WORKER_COUNT=1
```

Do not run `make do-up` unless I explicitly approve real DigitalOcean resource creation.

Constraints:
- Use Tailscale for worker/head communication.
- Do not expose Ray ports publicly.
- Use Terraform/OpenTofu for DigitalOcean workers.
- Use Multipass or a clearly documented equivalent for local Ubuntu VM lab.
- Keep secrets out of Git.
- Keep all paid resource creation behind explicit commands.
- Every creation path must have a destroy path.
- Workers must stream Ray Tune metrics back to the home server in real time.
- Write live reports suitable for a Codex subagent to inspect.

Boundaries:
- You may edit all files in this infra repo.
- You may create scripts, docs, Terraform, cloud-init, Python smoke jobs, and watcher utilities.
- Do not depend on the private ML repo internals. Provide configurable hooks for later integration.
- Do not create persistent cloud resources.

Iteration policy:
Work milestone by milestone. After each milestone, run the smallest verification. If a command fails, inspect logs, patch the cause, and rerun. Keep a short progress log in `artifacts/progress.md` when running locally.

Definition of done:
The local 3-worker VM lab can join the home Ray head, run a synthetic Tune job, write `artifacts/live/trial_events.jsonl`, generate `artifacts/live/latest_summary.md`, and cleanly destroy workers. The DigitalOcean Terraform configuration validates and plans one worker without exposing Ray publicly.
