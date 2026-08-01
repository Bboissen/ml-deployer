# Architecture

> Migration status: the active target is the GCP single-node design in [architecture-gcp.md](architecture-gcp.md). This document describes the preserved DigitalOcean/Ray implementation during transition.

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
  named AMS3 VPC
  Tailscale ephemeral nodes
  Ray workers
  local /data/tune
  local /data/demo-cache/<snapshot-hash>/

DigitalOcean persistent layer
  private infrastructure-state Space
  private Demo Bronze Space
    smoke/<test-pack-hash>/
    bronze/snapshots/<accepted-content-hash>/
  named AMS3 VPC
```

## Why this architecture

The workload is many independent CPU-bound ML trials: feature block tests, checkpoint-specific models, rolling validation folds, and HPO. The workers do not need shared memory; they need reliable scheduling, local data, and metric reporting back to the head.

Ray Tune provides scheduling and metric aggregation. Tailscale provides a private network so Ray does not need public exposure.

Spaces is the permanent infrastructure-state and Bronze layer. Droplet disks are disposable caches only, so destroying every Ray worker does not remove accepted Bronze snapshots or infrastructure state. The storage Terraform root and state lifecycle are independent from the worker root; routine `do-down` affects workers only. Silver and later data layers require a new reviewed phase.

## Network flow

```text
worker -> tailscale -> home Ray head:6379
worker <-> tailscale <-> home Ray head and scheduler ports
worker -> named AMS3 VPC route -> regional Spaces endpoint
trial -> tune.report(...) -> Ray head -> LiveJsonlCallback -> artifacts/live/trial_events.jsonl
watcher -> artifacts/live/latest_summary.md -> Codex/subagent review
```

## Repo boundaries

This infra repo is not the ML model repo. It should be able to run synthetic tests by itself and call external ML code through configurable commands later.

## VPC and storage authority

`terraform/digitalocean-storage` owns the persistent VPC and exports its UUID. Operators pass that exact UUID into `terraform/digitalocean-workers`; workers do not look up a VPC by name and the roots do not use Terraform remote-state coupling. A syntactically valid sentinel UUID is acceptable only for code-only plan validation. Live receipts must prove the worker used the exported UUID.

Workers use the VPC-local DNS resolver (the second-to-last address of the VPC CIDR) exclusively, as required for private Spaces routing. Phase 2 records that resolver, resolved endpoint addresses, VPC CIDR, and route/source-interface selection. Interface discovery follows metadata and the assigned private address; it never assumes a device name such as `eth1`. See [DigitalOcean's VPC-local resolver guidance](https://docs.digitalocean.com/products/networking/vpc/how-to/use-local-dns-resolver/).
