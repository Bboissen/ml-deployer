# Cost control

## Rules

- `terraform plan` is safe.
- `terraform apply` creates billable Droplets.
- `terraform destroy` removes them.
- Do not create Volumes, Snapshots, Reserved IPs, Spaces, or Kubernetes resources for this project unless explicitly required.

## Safe execution pattern

```bash
make do-plan DO_WORKER_COUNT=1
make do-up DO_WORKER_COUNT=1
# verify
make do-down
```

Scale only after smoke test passes.

## Post-run manual audit

Check DigitalOcean dashboard for:

- Droplets
- Volumes
- Snapshots
- Reserved IPs
- Load balancers
- Spaces buckets
- Databases
- Kubernetes clusters

This repo is designed to create Droplets and firewalls only.
