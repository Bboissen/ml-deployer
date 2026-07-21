# Goal: Build a secure temporary Ray worker infrastructure for ML HPO

## Outcome

Starting from an empty repo, create a deployable infrastructure system that lets the home server act as a Ray head/orchestrator and lets disposable Ubuntu workers join over Tailscale.

The system must support:

1. A local lab with 3 small Ubuntu VMs on the home server.
2. A DigitalOcean smoke test with 1 tiny worker in `ams3`.
3. A DigitalOcean production-sized burst with 10 workers.
4. Ray Tune / XGBoost / LightGBM style jobs launched from the home server.
5. Real-time metric flow from workers to the head.
6. A Codex/subagent-friendly result-review loop based on generated markdown and JSONL artifacts.
7. Safe teardown to stop cloud billing.
8. Persistent private state and Bronze Spaces buckets plus a named AMS3 VPC that survive every disposable worker teardown.

## Verification surface

The project is done only when these checks pass:

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
TF_VAR_vpc_uuid=00000000-0000-4000-8000-000000000000 \
  TF_VAR_vpc_name=phase1-plan-sentinel \
  make do-plan DO_WORKER_COUNT=1
make storage-init
make storage-validate
make storage-plan
```

The sentinel VPC values are only for the non-creating Phase 1 plan. They are forbidden for apply and live workers, which must use the exact storage outputs.

DigitalOcean apply is a separate manual authorization step:

```bash
make do-up DO_WORKER_COUNT=1
make ray-status EXPECTED_WORKERS=1
make smoke EXPECTED_WORKERS=1
make do-down
```

The 10-worker run is considered valid when:

```bash
make do-up DO_WORKER_COUNT=10
make ray-status EXPECTED_WORKERS=10
make tune-synth
make pull-artifacts
make do-down
```

## Constraints

- Do not expose Ray ports publicly.
- Use Tailscale for Ray head/worker communication.
- Use ephemeral/pre-authorized Tailscale auth keys for disposable workers.
- Keep secrets in environment variables or ignored local files only.
- Do not commit `.env`, `terraform.tfvars`, private keys, Terraform state, or artifacts.
- Terraform/OpenTofu `plan` must be safe to run without creating resources.
- DigitalOcean workers must be destroyed after use.
- Persistent state, Bronze objects, and the worker VPC have an independent lifecycle and must never be included in routine worker teardown.
- Local VM lab must be the first working test target.
- The infrastructure repository must not depend on the private ML repo internals. It should call configurable commands and scripts.

## Boundaries

Allowed:

- Terraform/OpenTofu for DigitalOcean worker lifecycle.
- Multipass for local Ubuntu VM lab.
- Tailscale for private networking.
- Ray for distributed execution.
- Ray Tune for HPO examples and smoke tests.
- Shell and Python scripts for orchestration.
- Optional integration with a separate ML repository by path or Git URL.

Not allowed:

- Hardcoding secrets.
- Public Ray dashboards.
- Creating persistent DigitalOcean volumes, snapshots, reserved IPs, Kubernetes clusters, or databases unless explicitly requested.
- Creating Spaces buckets or a persistent VPC outside the separately approved storage lifecycle.
- Silver and later data layers are out of scope and require a new reviewed phase.
- Training real production models inside this infra repo. This repo only proves the compute substrate and provides examples.

## Iteration policy

Work in this order:

1. Repo skeleton, docs, Makefile, ignored secrets, and local `.env` contract.
2. Home server Ray head scripts.
3. Local VM lab with Tailscale worker bootstrap.
4. Ray cluster verification and synthetic Ray Tune job.
5. Live result reporting and Codex/subagent review loop.
6. DigitalOcean Terraform/OpenTofu worker provisioning.
7. DO cloud-init hardening and worker join service.
8. Cost-control and destroy runbooks.
9. Code-only persistent Spaces and VPC design, without resource creation.
10. Separately authorized storage bootstrap, backend migration, and bounded cache smoke.
11. Final documentation pass.

After each step, run the smallest relevant verification. If a verification fails, fix it before expanding scope.

## Definition of done

- A new user can clone the repo, fill `.env`, and run the local lab without needing undocumented steps.
- DigitalOcean resources are only created by explicit `apply`/`do-up` commands.
- The local lab and DO workers join the home Ray head via Tailscale.
- Ray Tune results appear in real time under `artifacts/live/`.
- A Codex subagent can read the generated report and act on it.
- Every paid resource path has a documented teardown command.
- The state bucket, Demo Bronze bucket, and named VPC persist when every Ray Droplet is destroyed.
- Backend migration, credential revocation, paid smoke, and persistent-resource decommission remain explicit human gates.
