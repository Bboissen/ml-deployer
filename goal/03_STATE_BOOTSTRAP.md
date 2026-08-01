# Goal 03 — GCS remote-state bootstrap

```text
/goal Implement the separately controlled GCS OpenTofu state bootstrap for project example-project. Complete all code-only validations first. The live apply is a separate human gate.

Outcome:
Create tofu/gcp/bootstrap using local state initially. It manages only:
- GCS state bucket example-project-tofu-state;
- OpenTofu deployer service account;
- IAM needed for the human administrator to impersonate the deployer;
- bucket IAM needed for remote state.

State bucket configuration:
- location: us-central1;
- storage class: STANDARD;
- uniform bucket-level access: enabled;
- public access prevention: enforced;
- object versioning: enabled;
- soft delete: explicitly configured and documented;
- force_destroy: false;
- lifecycle.prevent_destroy: true;
- labels: project, environment, owner, managed_by, data_class=tofu-state;
- no lifecycle deletion rule.

Identity configuration:
1. Create `tofu-deployer` service account.
2. Grant the administrator `roles/iam.serviceAccountTokenCreator` on that service account.
3. Grant the deployer only the project roles required by the later roots; split overly broad privileges where practical.
4. Grant `roles/storage.objectAdmin` on the state bucket because OpenTofu must read, write, delete, and lock state objects.
5. Do not create any service-account key.

Bootstrap-state rules:
- bootstrap root retains local state under an ignored mode-0700 directory;
- local state files are mode 0600;
- document encrypted backup of bootstrap state;
- bootstrap state is never uploaded into the same backend it creates unless a later reviewed migration is designed;
- no routine bootstrap destroy target.

Backend convention for later roots:
- backend block is partial: `backend "gcs" {}`;
- bucket and prefix supplied at init;
- prefixes:
  - gcp/storage
  - gcp/network
  - gcp/training-node
- authentication uses ADC plus `GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT`;
- do not pass credentials or access tokens through backend-config.

One-use live authorization:
Authorization receipt must contain:
- authorization_id;
- project_id exactly example-project;
- root exactly tofu/gcp/bootstrap;
- billing_account_id;
- bucket name;
- plan_sha256;
- expected add/change/destroy counts;
- max_estimated_cost;
- issued_at and expires_at;
- operator identity;
- one-use nonce.

Apply wrapper:
- verifies mode 0600;
- verifies expiry;
- recalculates plan hash;
- rejects any destroy count;
- writes and fsyncs a consumed marker before apply;
- never allows reuse after success or failure;
- records a non-secret receipt under artifacts/receipts/.

Code-only validation:
- tofu fmt;
- tofu init -backend=false;
- tofu validate;
- tofu plan saved to a binary plan;
- tofu show -json piped to plan-policy validator;
- test that public access, force_destroy, versioning-off, or missing prevent_destroy plans are rejected;
- test authorization expiry, tampering, reuse, and plan mismatch.

Human-authorized live validation:
1. Apply the exact reviewed plan.
2. Verify bucket location, storage class, public access prevention, UBLA, versioning, soft delete, and labels.
3. Verify no service-account key exists.
4. Initialize a disposable test root against prefix `gcp/backend-smoke`.
5. Apply one harmless local/random resource to prove state write.
6. Attempt a concurrent plan/apply and confirm state locking.
7. Inspect object generations.
8. Restore a prior state generation in a documented dry-run recovery exercise.
9. Delete only the disposable test prefix, not the bucket.

Stop condition:
After state acceptance, stop. Do not create data buckets, VPC, or VM in this phase.
```
