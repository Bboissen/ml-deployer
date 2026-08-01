# AWS OpenTofu goal pack

This pack adds an AWS implementation beside the existing DigitalOcean implementation. The provider roots remain separate and DigitalOcean is not removed.

The AWS runtime provisions exactly one EC2 instance for native ML training with Polars, DuckDB, PyArrow, LightGBM, XGBoost, and CatBoost. It does not extend or test the existing local VM lab, home-server Ray head, or distributed Ray worker cluster. Ray is optional and may run locally on the one EC2 instance for HPO only.

## Recommended repository strategy

Use one repository with provider-separated directories. Develop this pack on a temporary feature branch such as `feat/aws-opentofu`, then merge it. Do not maintain permanent long-lived branches per cloud provider; they will drift and duplicate shared fixes.

## AWS architecture summary

| Concern | AWS implementation |
|---|---|
| Human authentication | MFA-protected `sposhfi-admin` IAM console user plus AWS CLI `aws login`; no IAM access keys |
| OpenTofu state | Private, versioned S3 bucket with native S3 lockfile (`use_lockfile=true`) |
| Data lake | Separate S3 Standard buckets for Bronze, Silver, and artifacts |
| Administrative shell | AWS Systems Manager Session Manager; no inbound SSH and no EC2 key pair |
| Standard training | One disposable EC2 instance with encrypted auto-delete EBS volumes |
| Recoverable Spot | One single-AZ Auto Scaling Group with min/max/desired exactly 1, plus one separately managed encrypted EBS workspace reattached after replacement |
| Hard runtime limit | One-time EventBridge Scheduler cleanup action plus local systemd fallback |
| Durable outputs | Immutable artifacts and selected checkpoint backups in S3 |
| Hot working state | Local EBS workspace, never S3 mounted as the active training filesystem |

## Files

- `00_MASTER_AWS_GOAL.md`
- `01_ACCOUNT_BILLING_AND_WORKSTATION_AWS.md`
- `02_REPOSITORY_SCAFFOLD_AWS.md`
- `03_STATE_BOOTSTRAP_AWS.md`
- `04_STORAGE_LAKE_AWS.md`
- `05_NETWORK_IAM_AND_COMPUTE_AWS.md`
- `06_FREE_TIER_SMOKE_AWS.md`
- `07_DATA_STAGING_AWS.md`
- `08_NATIVE_TRAINING_RUNTIME_AWS.md`
- `09_SCALE_PROFILES_AWS.md`
- `09A_SPOT_RECOVERY_AWS.md`
- `10_SINGLE_NODE_RAY_HPO_AWS.md`
- `11_FINAL_ACCEPTANCE_AWS.md`
- `AWS_PARALLEL_ARCHITECTURE_SETUP.md`

## Values that must be resolved before implementation

```bash
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="us-east-1"
AWS_AVAILABILITY_ZONE=""  # select after instance-type, quota, and Spot discovery
AWS_ADMIN_EMAIL=""
AWS_PROFILE="sposhfi-admin"
```

Bucket names should include the account ID because S3 bucket names are globally unique:

```text
spotify-predictor-<account-id>-tofu-state
spotify-predictor-<account-id>-bronze
spotify-predictor-<account-id>-silver
spotify-predictor-<account-id>-artifacts
```
