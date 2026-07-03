# Runbook: DigitalOcean temporary workers

## Purpose

Provision short-lived DigitalOcean Droplets as Ray workers that join the home Ray head over Tailscale.

## Prerequisites

- DigitalOcean API token.
- Existing DO SSH key name.
- Tailscale auth key.
- Home Ray head running on Tailscale IP.
- Terraform or OpenTofu installed.

## Smoke test

The default smoke-test worker is intentionally cheap:

- Region: `ams3`
- Size slug: `s-1vcpu-512mb-10gb`
- Worker count: `1`

This size is only intended to verify provisioning, Tailscale, and Ray worker join. The worker bootstrap installs minimal Ray dependencies for this path. Use a larger slug and an ML-capable worker image/bootstrap before running heavier Tune jobs.

```bash
source .env
make head-start
make do-init
make do-plan DO_WORKER_COUNT=1
make do-up DO_WORKER_COUNT=1
make ray-status EXPECTED_WORKERS=1
make smoke EXPECTED_WORKERS=1
make do-down
```

## Full 10-worker run

```bash
source .env
make head-start
make do-up DO_WORKER_COUNT=10
make ray-status EXPECTED_WORKERS=10
make sync-data DATA_DIR=/path/to/compact/tune_slice
make run-tune CONFIG=configs/tune_synthetic.yaml
make pull-artifacts OUT_DIR=/path/to/local/artifacts
make do-down
```

## Failure handling

If workers fail to join:

```bash
terraform -chdir=terraform/digitalocean-workers output
ssh root@<worker-public-ip> 'journalctl -u ray-worker -n 200 --no-pager'
ssh root@<worker-public-ip> 'tailscale status'
ssh root@<worker-public-ip> 'tailscale ip -4'
```

If cost safety is more important than debugging:

```bash
make do-down
```
