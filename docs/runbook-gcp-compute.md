# GCP disposable compute runbook

## Plan-only workflow

```bash
make gcp-network-init
make gcp-network-plan
make gcp-compute-init
make gcp-compute-plan PROFILE=smoke-free
```

Review plan JSON and the exact binary plan. Only then issue a short-lived authorization tied to that plan. Applying is a billable live action and requires an explicit human gate:

```bash
make gcp-authorize ROOT=tofu/gcp/training-node PROFILE=smoke-free PLAN=.gcp-runtime/plans/training-node.tfplan
make gcp-up ROOT=tofu/gcp/training-node PROFILE=smoke-free PLAN=.gcp-runtime/plans/training-node.tfplan AUTH=.gcp-runtime/authorizations/RECEIPT.json
```

Connect only through `gcloud compute ssh INSTANCE --zone us-central1-a --tunnel-through-iap`. Inspect serial logs and `/var/lib/spotify-ml/bootstrap-status.json`. Verify identity, labels, CPU/RAM/disk, Bronze/Silver fixture read, denied data write, artifact creation, local disk, Python, DuckDB, and Polars.

Explicitly tear down before 45 minutes with `make gcp-down PROFILE=smoke-free`, then run `make gcp-audit`. Confirm no VM, disk, reserved address, snapshot, image, load balancer, NAT, or GKE resource remains. Persistent buckets and the intentionally persistent network remain.

On failure, capture non-secret serial and journal diagnostics and tear compute down immediately. The consumed authorization cannot be retried; create a new plan and authorization.
