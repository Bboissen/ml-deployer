# Architecture

## Production topology

```text
home-server
  tailscale0: 100.x.y.z
  ray head: binds to tailscale0
  artifacts/live/
  artifacts/ray_results/
  Terraform/OpenTofu runner
  Codex/subagent runner

DigitalOcean temporary workers
  Ubuntu
  Tailscale ephemeral nodes
  Ray workers
  local /data/tune
```

## Why this architecture

The workload is many independent CPU-bound ML trials: feature block tests, checkpoint-specific models, rolling validation folds, and HPO. The workers do not need shared memory; they need reliable scheduling, local data, and metric reporting back to the head.

Ray Tune provides scheduling and metric aggregation. Tailscale provides a private network so Ray does not need public exposure.

## Network flow

```text
worker -> tailscale -> home Ray head:6379
worker <-> tailscale <-> home Ray head and scheduler ports
trial -> tune.report(...) -> Ray head -> LiveJsonlCallback -> artifacts/live/trial_events.jsonl
watcher -> artifacts/live/latest_summary.md -> Codex/subagent review
```

## Repo boundaries

This infra repo is not the ML model repo. It should be able to run synthetic tests by itself and call external ML code through configurable commands later.
