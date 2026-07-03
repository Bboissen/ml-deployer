# Runbook: local Ubuntu VM lab

## Purpose

Validate the whole worker lifecycle before spending DigitalOcean credit.

## Prerequisites

- Ubuntu home server.
- Tailscale already running on the home server.
- Multipass installed.
- A reusable, ephemeral, pre-authorized Tailscale auth key for local test workers.

Install Multipass if needed:

```bash
sudo snap install multipass
```

## Steps

```bash
cp .env.example .env
source .env
make venv
make install-head
make head-start
make local-lab-up WORKER_COUNT=3
make ray-status EXPECTED_WORKERS=3
make smoke EXPECTED_WORKERS=3
make tune-synth
make watch-once
make local-lab-down
```

## Expected result

- `ray status` shows the head plus 3 worker nodes.
- `artifacts/live/trial_events.jsonl` exists.
- `artifacts/live/latest_summary.md` contains top trials and recent events.

## Notes for 1 core / 2 GB RAM workers

Use 1 CPU per trial and small synthetic jobs. This lab proves infrastructure, not model performance.

By default, `RAY_HEAD_CPUS=0` keeps the home server as the Ray head/orchestrator and schedules Tune trials on workers. Set `RAY_HEAD_CPUS` above `0` only if you want the home server to contribute compute.

## Tailscale device names

The local lab requests stable hostnames such as `ray-lab-worker-1`. If a VM is deleted before it can log out of Tailscale, the admin console can temporarily show stale ephemeral devices and Tailscale may suffix the next registration, for example `ray-lab-worker-1-1`. `make local-lab-down` logs workers out before deleting them; remove any older offline duplicates from the Tailscale admin console.
