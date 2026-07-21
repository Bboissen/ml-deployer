# Spotify Ray Infra Goal Pack

This repository template builds a temporary ML-oriented Ray worker fleet for hyperparameter search and feature exploration.

Target end state:

- Home server is the **Ray head/orchestrator**.
- Temporary workers join over **Tailscale**.
- Local lab phase uses **3 small Ubuntu VMs** on the home server.
- DigitalOcean smoke phase uses **1 tiny Ubuntu Droplet** in `ams3`; production bursts can scale to larger worker counts and sizes after the smoke test passes.
- Workers run Ray Tune / XGBoost / LightGBM style jobs and stream metrics back to the home server in real time.
- The head, workers, and driver pin Python 3.14.4 and `ray==2.56.0` exactly so the separate `demo` driver can connect.
- Terraform/OpenTofu creates and destroys DigitalOcean workers on demand.
- DigitalOcean Spaces permanently holds infrastructure state and accepted Demo Bronze snapshots; worker disks are temporary caches.
- A persistent named AMS3 VPC is created independently and attached explicitly to every disposable Droplet.
- No Ray control ports are exposed on public interfaces.

## Repository phases

| Phase | Backend | Purpose |
|---|---|---|
| Phase 0 | Home server only | Install and verify Ray head on Tailscale IP. |
| Phase 1 | 3 local Ubuntu VMs | Validate worker bootstrapping, Tailscale, Ray worker join, metrics streaming, and result-review loop. |
| Phase 2 | 1 tiny DigitalOcean worker | Validate Terraform/OpenTofu, cloud-init, DO firewall, Tailscale auth key, and Ray join with `s-1vcpu-512mb-10gb` in `ams3`. This is a smoke test, not an HPO worker size. |
| Phase 3 | 10 DigitalOcean workers | Run real small-batch HPO / feature-search jobs. |

The storage workstream has separate gates: Phase 1 is code-only design and validation; Phase 2 covers explicitly authorized storage bootstrap, backend migration, and bounded cache smoke. See [`docs/runbook-storage.md`](docs/runbook-storage.md).

The current storage scope is Bronze only. Silver and later data layers require a new reviewed phase.

## Important security model

- Use a **reusable, ephemeral, pre-authorized Tailscale auth key** for short-lived workers.
- Keep `DO_TOKEN`, `TS_AUTH_KEY`, Terraform state, `.env`, and `terraform.tfvars` out of Git.
- Keep Spaces and backend credentials environment-only; workers receive short-lived presigned download plans, never long-lived storage secrets.
- Bind Ray head to the home server's Tailscale IP only.
- Workers connect to the Ray head over Tailscale.
- DigitalOcean public firewall exposes no Ray ports.
- Public SSH is optional and should be restricted to your admin IP CIDR.

## Quickstart

```bash
cp .env.example .env
# edit .env with DO token, Tailscale key, and head Tailscale IP

make venv
make install-head
make head-start
make ray-status
```

The head lifecycle is isolated in `spotify-ray-head.service`; `make head-stop` stops only that systemd user control group. Run `make head-lifecycle-check` to verify the source policy. Host-global `ray stop` is forbidden for the shared home server.

All validation is local through `make` targets.

### Persistent storage code-only validation

```bash
make storage-init
make storage-validate
make storage-plan
```

These targets do not create resources. There is intentionally no routine `storage-down` target. Bootstrap apply, backend activation/migration, key revocation, paid smoke, and persistent-resource decommission each require a separate human gate.

### Local VM lab

```bash
make local-lab-up WORKER_COUNT=3
make ray-status
make smoke
make tune-synth
make watch
make local-lab-down
```

### DigitalOcean smoke test

```bash
make do-init
TF_VAR_vpc_uuid=<storage-output-uuid> \
  TF_VAR_vpc_name=<storage-output-name> \
  make do-plan DO_WORKER_COUNT=1
make do-up DO_WORKER_COUNT=1
make ray-status
make smoke
make do-down
```

### Full DigitalOcean run

```bash
make do-up DO_WORKER_COUNT=10
make sync-data DATA_DIR=/path/to/compact/tune_slice
make run-tune CONFIG=configs/tune_synthetic.yaml
make pull-artifacts OUT_DIR=/path/to/local/artifacts
make do-down
```

## Codex use

Start with [`prompts/CODEX_GOAL_MAIN.md`](prompts/CODEX_GOAL_MAIN.md). It contains the durable Goal prompt for creating this repo from scratch, implementing it, testing it locally, then testing it on DigitalOcean.

Subagent prompts are in [`prompts/`](prompts/). The watcher writes review tasks into `artifacts/inbox/` so a Codex subagent can inspect HPO results while jobs are still running.

## Git workflow

Use a feature branch for infrastructure changes unless you explicitly intend to update `main`. Before each commit, run `git status --short --branch`, stage only task-related files, and run the smallest relevant local `make` checks. Never commit `.env`, Terraform state, `terraform.tfvars`, keys, data, model files, or generated artifacts.
