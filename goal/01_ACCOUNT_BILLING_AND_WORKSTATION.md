# Goal 01 — Account, billing, and workstation

```text
/goal Build a beginner-safe GCP account and workstation setup guide plus a read-only diagnostic script for project example-project. Do not create or mutate cloud resources.

Deliverables:
- docs/account-setup-gcp.md
- scripts/gcp/doctor.sh
- scripts/gcp/account_check.sh
- Make targets gcp-doctor and gcp-account-check
- JSON audit output under artifacts/audits/

Manual account guide requirements:

A. Google Payments and billing
1. Verify the Google Payments legal name, profile country, billing address, and card billing address are internally consistent.
2. Explain that French nationality while living in the USA is not itself a blocker; payment-profile/card/address inconsistency is the material issue.
3. Verify that the Cloud Billing account is open and not suspended.
4. Record billing account ID, display name, currency, promotional-credit balance, expiration, and whether the account is Free Trial or paid.
5. If billing is not linked to the project, document the console and gcloud link steps but do not execute them automatically.
6. Explicitly stop the workflow if OR_BACR2_44 or any payments-profile restriction remains unresolved.

B. Project validation
Use project ID example-project.
Validate:
- project exists;
- lifecycle state is ACTIVE;
- project number can be read;
- billing is enabled;
- current user has adequate bootstrap permissions;
- region is us-central1;
- zone is us-central1-a.

C. Budget controls
1. Create a billing-account budget scoped to this project.
2. Target amount: 10 in the billing account's currency, or the documented equivalent of EUR 10 if the billing account currency differs.
3. Actual-spend thresholds: 50%, 80%, 100%.
4. Forecast threshold: 100% if available.
5. Send alerts to billing admins and project owners.
6. State plainly that alerts-only budgets do not cap Compute Engine or Cloud Storage.
7. Do not claim the preview spend-cap feature protects Compute Engine or Cloud Storage.
8. Hard safeguards are implemented in code: allowlisted profiles, one-use authorization, plan SHA binding, maximum runtime, automatic VM deletion, and post-run audit.

D. Local tools
Document install and verification for:
- gcloud CLI;
- OpenTofu;
- git;
- make;
- Python 3.12+;
- jq;
- shellcheck;
- ruff;
- pytest;
- optional trivy config scanner.

E. Authentication
Document and verify:
- gcloud auth login
- gcloud auth application-default login
- gcloud config set project example-project
- gcloud config set compute/region us-central1
- gcloud config set compute/zone us-central1-a

Do not create a service-account key. The bootstrap uses user ADC. Later roots use service-account impersonation.

F. Required APIs
Audit these APIs and document a separately approved enablement command:
- serviceusage.googleapis.com
- cloudresourcemanager.googleapis.com
- iam.googleapis.com
- iamcredentials.googleapis.com
- compute.googleapis.com
- storage.googleapis.com
- iap.googleapis.com
- oslogin.googleapis.com
- logging.googleapis.com
- monitoring.googleapis.com
- billingbudgets.googleapis.com only if the budget is managed through code

account_check.sh requirements:
- read-only;
- fail if gcloud or tofu is missing;
- print active user and project;
- validate exact project ID;
- print project number and lifecycle state;
- print billing-enabled status without exposing payment data;
- print region and zone;
- print enabled required APIs;
- print relevant regional CPU and IP quotas where available;
- verify ADC can obtain a token but never print the token;
- verify local clock is reasonably synchronized;
- support --json and write mode 0600 audit output;
- exit nonzero for any unmet prerequisite.

Validation:
- make gcp-doctor
- make gcp-account-check
- scripts/gcp/account_check.sh --json
- inspect the JSON and confirm no secret or token is present
- run a repository secret scan

Stop condition:
Stop after documentation and diagnostics. Do not link billing, enable APIs, mutate IAM, create a bucket, or create a VM.
```

## Human commands after review

```bash
export GCP_PROJECT_ID='example-project'

gcloud auth login
gcloud auth application-default login

gcloud config set project "$GCP_PROJECT_ID"
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a

gcloud projects describe "$GCP_PROJECT_ID"
gcloud billing projects describe "$GCP_PROJECT_ID"
gcloud services list --enabled --project "$GCP_PROJECT_ID"
```

Do not proceed to API enablement until `gcloud billing projects describe` reports billing enabled.
