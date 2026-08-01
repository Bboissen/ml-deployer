# GCP cost control

Budgets alert; they do not stop Compute Engine or GCS. Operational limits are enforced by allowlisted profiles, exact-plan authorization, a cost field in the receipt, one VM maximum, `max_run_duration`, `instance_termination_action = DELETE`, auto-delete disks, and a post-run resource audit.

The first smoke uses `e2-micro`, 10 GB `pd-standard`, and at most 45 minutes. It validates infrastructure, not ML performance. An ephemeral public IPv4 may incur cost and is released with the VM.

At an illustrative Standard regional rate of USD 0.02 per GB-month, storage before free-tier credit and request charges is approximately:

| Stored data | Monthly estimate |
|---:|---:|
| 5 GB | USD 0.10 |
| 10 GB | USD 0.20 |
| 25 GB | USD 0.50 |
| 50 GB | USD 1.00 |
| 100 GB | USD 2.00 |

Live pricing must be refreshed before authorization. Object request charges can dominate tiny-file layouts, so record object counts and prefer Parquet objects around 64–256 MB where the data contract permits. Keep storage and compute in `us-central1`; do not enable Autoclass or cross-region replication.

Bronze versioning and seven-day soft delete can retain replaced or deleted bytes, so inventory must include noncurrent and soft-deleted generations. Silver versioning is off by default. Artifact deletion applies only to `artifacts/tmp/` and `artifacts/runs/unaccepted/` after seven days; accepted and pinned artifacts have no lifecycle deletion rule.
