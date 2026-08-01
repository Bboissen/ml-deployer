# GCP OpenTofu Goal Pack

This pack extends `Bboissen/Ray_terraform` with a GCP path for persistent Google Cloud Storage and disposable single-node ML compute.

## Fixed project constants

```dotenv
GCP_PROJECT_ID=example-project
GCP_REGION=us-central1
GCP_ZONE=us-central1-a
GCP_STATE_BUCKET=example-project-tofu-state
GCP_BRONZE_BUCKET=example-project-bronze
GCP_SILVER_BUCKET=example-project-silver
GCP_ARTIFACT_BUCKET=example-project-artifacts
```

The project ID is syntactically valid and exactly 30 characters, which is the maximum length for a Google Cloud project ID. Bucket names are globally unique because they are derived from the globally unique project ID, but every live phase must still verify availability before apply.

## Core architecture

```text
home server / workstation
├── gcloud + OpenTofu
├── infrastructure repository
├── separate ML repository
└── initial Bronze/Silver upload

Google Cloud project
├── GCS state bucket                 persistent
├── GCS Bronze bucket                persistent, source truth
├── GCS Silver bucket                persistent, derived snapshots
├── GCS artifact bucket              persistent, lifecycle-managed
├── custom VPC and subnet            persistent
├── IAP-only administrative ingress  persistent
└── one training VM                  disposable, auto-deleted
    ├── local staged dataset
    ├── Polars / DuckDB / PyArrow
    ├── LightGBM / XGBoost / CatBoost
    └── Ray Tune later, single-node only
```

Google Cloud Storage is “S3-like” object storage, but the implementation uses the native `gs://` API and a native GCS OpenTofu backend. Do not create HMAC credentials merely to imitate the S3 protocol.

## Why `us-central1`

- Eligible region for the monthly `e2-micro` Compute Engine Free Tier.
- Eligible region for the first 5 GB-months of Standard Cloud Storage Free Tier.
- Regional GCS and Compute Engine can be colocated, avoiding Cloud Storage outbound transfer charges for same-region reads.
- A regional bucket is cheaper and more predictable than dual-region or multi-region storage for this workload.

## Cost posture with approximately EUR 10 available

- First compute smoke: `e2-micro`, 10 GB `pd-standard`, 45-minute maximum runtime, automatic VM deletion.
- `e2-micro` proves infrastructure only; it is not an ML training server.
- Standard regional storage is roughly USD 0.02/GB-month before free-tier allowances and operations. A representative 25 GB total footprint is about USD 0.50/month before free-tier credits.
- Budget alerts do not cap Compute Engine or Cloud Storage spending. The real safeguards are plan allowlists, one-use authorization receipts, `max_run_duration`, `instance_termination_action = "DELETE"`, and post-run resource audits.
- A public ephemeral IPv4 address is billable after a small free allowance. It is permitted only when needed for outbound package installation; no public inbound firewall rule is permitted.

## Prompt order

1. `00_MASTER_GCP_GOAL.md`
2. `01_ACCOUNT_BILLING_AND_WORKSTATION.md`
3. `02_REPOSITORY_SCAFFOLD.md`
4. `03_STATE_BOOTSTRAP.md`
5. `04_STORAGE_LAKE.md`
6. `05_NETWORK_IAM_AND_COMPUTE.md`
7. `06_FREE_TIER_SMOKE.md`
8. `07_DATA_STAGING.md`
9. `08_NATIVE_TRAINING_RUNTIME.md`
10. `09_SCALE_PROFILES.md`
11. `10_SINGLE_NODE_RAY_HPO.md`
12. `11_FINAL_ACCEPTANCE.md`

Each prompt is a separate Codex goal. Run one prompt at a time. Paid or persistent mutations require a separate human authorization at the phase boundary.

## Phase gates

| Phase | Mutation permitted | Expected spend | Gate |
|---|---:|---:|---|
| Local scaffold | No | EUR 0 | lint, test, validate |
| Account setup | Manual console/CLI only | EUR 0 | billing and APIs confirmed |
| State plan | No | EUR 0 | plan policy passes |
| State apply | Yes, explicit | cents/month | remote backend and lock pass |
| Storage apply | Yes, explicit | low monthly | fixture upload/restore pass |
| `e2-micro` smoke | Yes, explicit | near zero | VM reads/writes GCS and deletes itself |
| Paid small VM | Yes, new authorization | capped per run | native ML smoke passes |
| High-end profiles | Plan only initially | EUR 0 | quota, availability, price receipt |
| High-end run | Yes, per-run authorization | capped per run | benchmark and teardown pass |
| Ray Tune | Yes, per-run authorization | capped per run | single-node HPO passes |

## Non-negotiable rules

- No GKE, Cloud SQL, load balancer, static external IPv4, service-account key, or public bucket.
- No public SSH (`0.0.0.0/0:22`). IAP ingress only from `35.235.240.0/20`.
- No routine command destroys persistent buckets or their state.
- No full dataset upload before fixture validation.
- No paid apply without a one-use authorization bound to the exact plan SHA-256.
- No Ray until native single-node training works.
- Infrastructure repository remains independent from private ML model internals.
