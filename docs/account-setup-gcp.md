# GCP account and workstation setup

This guide is read-only until a command is explicitly marked as a human action. The fixed project is `example-project`, region `us-central1`, zone `us-central1-a`.

## Payments and billing gate

In Google Payments, verify that the legal name, payment-profile country, billing address, and the card billing address agree. French nationality while living in the USA is not itself a blocker; inconsistent identity, address, country, or card data is. Stop if `OR_BACR2_44` or any payment-profile restriction remains unresolved.

In Cloud Billing, record privately the billing account ID, display name, currency, promotional-credit balance and expiration, and whether the account is Free Trial or paid. Confirm the account is open, not suspended, and linked to the exact project. If it is not linked, use the Cloud Console billing page or review `gcloud billing projects link PROJECT --billing-account ACCOUNT`; do not automate that mutation.

Create a project-scoped budget of 10 in the billing-account currency, or document the equivalent of EUR 10. Configure actual-spend alerts at 50%, 80%, and 100%, forecast 100% when available, and notify billing administrators and project owners. Alerts do not cap Compute Engine or GCS, and the preview spend-cap feature must not be treated as protection for them. The enforceable controls are profile allowlists, plan-hash authorization, runtime deadlines, automatic deletion, and audits.

## Local tools

Install and verify `gcloud`, OpenTofu, Git, Make, Python 3.12+, `jq`, `shellcheck`, `ruff`, and `pytest`. `trivy config` is optional. Run:

```bash
make gcp-doctor
```

Python-based development tools, including the portable ShellCheck package, can be installed into the repository virtual environment with `pip install -r requirements-dev.txt`.

## Human authentication commands

These authenticate but do not create infrastructure:

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project example-project
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a
```

Use user ADC for bootstrap. Later roots impersonate `tofu-deployer`; never create a service-account JSON key or HMAC key.

## Read-only project gate

```bash
make gcp-account-check
scripts/gcp/account_check.sh --json
```

The check verifies project lifecycle, project number, billing status, region, zone, ADC token acquisition without printing the token, required APIs, selected quotas, and local clock state. Audit JSON is mode 0600 and ignored.

Required APIs are Service Usage, Cloud Resource Manager, IAM, IAM Credentials, Compute Engine, Storage, IAP, OS Login, Logging, and Monitoring. Billing Budgets is required only if budgets are managed through code. API enablement is a separate reviewed mutation, for example `gcloud services enable ... --project PROJECT`; do not run it during diagnostics.

Stop if billing is disabled, the project is not `ACTIVE`, APIs are missing, ADC fails, quota is insufficient, or the configured project/region/zone differs.
