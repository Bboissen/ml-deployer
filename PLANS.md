# PLANS.md

## Milestone 1: Repository foundation

Deliverables:

- `.gitignore`
- `.env.example`
- `Makefile`
- `README.md`
- `GOAL.md`
- `AGENTS.md`
- `docs/`

Checks:

```bash
make dryrun
```

## Milestone 2: Home server Ray head

Deliverables:

- `scripts/head/install_head.sh`
- `scripts/head/start_head.sh`
- `scripts/head/stop_head.sh`
- `scripts/head/ray_status.sh`

Checks:

```bash
make install-head
make head-start
make ray-status
```

## Milestone 3: Local VM lab

Deliverables:

- `scripts/local-vms/create_local_lab.sh`
- `scripts/local-vms/destroy_local_lab.sh`
- `cloud-init/local-worker.yaml.tftpl`

Checks:

```bash
make local-lab-up WORKER_COUNT=3
make ray-status EXPECTED_WORKERS=3
make smoke EXPECTED_WORKERS=3
make local-lab-down
```

## Milestone 4: Ray Tune and result reporting

Deliverables:

- `src/spotify_ray_infra/tune_synthetic.py`
- `src/spotify_ray_infra/live_callback.py`
- `scripts/agentic/watch_results.py`
- `prompts/CODEX_SUBAGENT_RESULT_REVIEW.md`

Checks:

```bash
make tune-synth
make watch-once
```

## Milestone 5: DigitalOcean workers

Deliverables:

- `terraform/digitalocean-workers/`
- `cloud-init/do-worker.yaml.tftpl`
- `scripts/do/render_inventory.sh`
- `scripts/do/sync_data.sh`
- `scripts/do/pull_artifacts.sh`

Checks:

```bash
make do-init
make do-validate
make do-plan DO_WORKER_COUNT=1
```

Manual cloud check:

```bash
make do-up DO_WORKER_COUNT=1
make ray-status EXPECTED_WORKERS=1
make smoke EXPECTED_WORKERS=1
make do-down
```

## Milestone 6: Ten-worker burst

Deliverables:

- Final runbook.
- Final security checklist.
- Cost-control checklist.

Checks:

```bash
make do-up DO_WORKER_COUNT=10
make ray-status EXPECTED_WORKERS=10
make tune-synth
make pull-artifacts
make do-down
```
