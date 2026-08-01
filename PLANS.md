# PLANS.md

## Paused migration: GCP single-node native execution

The ordered Goals 00–11 in `goal/` describe the GCP path, but owner decision stopped that migration on 2026-08-01 after bounded Goal 04 storage verification. Do not advance the GCP goals without a new explicit decision. AWS integration will be planned independently on a new branch. The existing DO/Ray milestones below remain supported.

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
TF_VAR_vpc_uuid=00000000-0000-4000-8000-000000000000 \
  TF_VAR_vpc_name=phase1-plan-sentinel \
  TF_VAR_vpc_cidr=10.255.240.0/20 \
  make do-plan DO_WORKER_COUNT=1
```

These sentinel values are code-only plan inputs. Apply and live workers must use the exact persistent storage outputs.

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

## Storage workstream: persistent Bronze and disposable caches

### Phase 0: accepted runtime base

- Python 3.14.4 and `ray==2.56.0` are pinned across head, driver, and workers.
- Local worker lifecycle and non-creating DigitalOcean worker plan are green.

### Phase 1: code-only storage design

Deliverables:

- Independent `terraform/digitalocean-storage/` root for one VPC, one private state bucket, and one private Bronze bucket in AMS3.
- Explicit VPC UUID input on every disposable worker.
- Backend-disabled init, validation, and semantic plan checks.
- Inactive S3-compatible backend example and one consolidated storage runbook.
- Documentation for credential boundaries, lifecycle protection, receipts, cache protocol, and decommission.

Checks:

```bash
make lint-shell
make python-check
make dryrun
make do-init
make do-validate
TF_VAR_vpc_uuid=00000000-0000-4000-8000-000000000000 \
  TF_VAR_vpc_name=phase1-plan-sentinel \
  TF_VAR_vpc_cidr=10.255.240.0/20 \
  make do-plan DO_WORKER_COUNT=1
make storage-init
make storage-validate
make storage-plan
```

The sentinel VPC values are valid only for this non-creating code plan. Phase 1 must not apply infrastructure, activate or migrate a backend, mutate credentials, run a paid smoke, or modify cloud-init. Apply and live workers must use the exact storage outputs.

### Phase 2: storage/cache smoke build

Deliverables:

- A PyArrow-version-pinned deterministic 512 MiB/16-object pack protocol with a tiny offline profile.
- Canonical manifest, explicit Bronze publication/presign primitives, and a locked atomic worker cache.
- One-use authorization, fresh size/cost validation, cleanup rendering, workspace isolation, and receipt validation primitives.
- One offline selftest covering positive and adversarial protocol/control fixtures.

Check:

```bash
make storage-phase2-selftest
```

This code-only prerequisite does not generate the full pack, query live APIs, create a workspace, publish objects, arm cleanup, apply/destroy infrastructure, migrate state, or prove live network behavior. The exact-flag-gated controller and worker entrypoints now implement the frozen sequence, but Phase 2 is not ready for live execution until they pass separate adversarial review and produce live cleanup, transfer, cloud identity, cache, network, Ray, and destroy evidence.

### Phase 2 live-execution gates

1. Recheck live AMS3 size price and availability.
2. Human-authorize persistent storage/VPC bootstrap.
3. Verify separate state-bucket-scoped and Bronze-bucket-scoped identities, then revoke the broad bootstrap key at a separate human gate.
4. Activate and migrate each backend in reviewed commits; prove Spaces lock contention before accepting migration.
5. Human-authorize the 512 MiB storage/cache smoke, capped at 20 minutes per phase and the approved budget.
6. Stop after smoke for semantic receipt review; do not auto-promote to production staging.

Silver and later data layers require a new reviewed phase and are not supported by this phase.
