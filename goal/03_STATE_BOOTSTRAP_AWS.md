# Goal 03 — S3 remote-state bootstrap

```text
/goal Implement the separately controlled S3 OpenTofu state bootstrap. Complete all code-only validations first. The live apply is a separate human gate.

Outcome:
Create `tofu/aws/bootstrap` using local state initially. It manages only:
- S3 state bucket `spotify-predictor-<account_id>-tofu-state`;
- account-level S3 public access block if explicitly approved and not already enabled;
- IAM role `spotify-tofu-deployer`;
- trust policy allowing only the exact approved `sposhfi-admin` IAM user ARN to assume the deployer role;
- bucket policy and IAM permissions needed for remote state.

State bucket configuration:
- region: approved AWS Region;
- storage class: S3 Standard;
- S3 Block Public Access: all four settings true;
- Object Ownership: Bucket owner enforced; ACLs disabled;
- versioning enabled;
- default encryption SSE-S3 for V0 unless a later KMS decision is approved;
- deny non-TLS requests with a bucket policy;
- force_destroy=false;
- lifecycle.prevent_destroy=true;
- tags: project, environment, owner, managed_by, data_class=tofu-state;
- no lifecycle expiration rule in V0;
- no website configuration;
- no Object Lock in V0;
- no cross-region replication.

Identity configuration:
1. Create `spotify-tofu-deployer` role, not an IAM user.
2. Trust only `arn:aws:iam::000000000000:user/sposhfi-admin` until a separately reviewed identity design replaces it.
3. Require an external ID only if a cross-account design is introduced; do not invent one for same-account role assumption.
4. Grant only the infrastructure actions required by later AWS roots; split broad policies by service where practical.
5. Grant state-bucket object read/write/delete/list permissions only for the exact state bucket and prefixes.
6. Do not create an access key, login profile, or service-specific credential.

Bootstrap-state rules:
- bootstrap root retains local state under an ignored mode-0700 directory;
- local state and plan files are mode 0600;
- document encrypted offline backup of bootstrap state;
- bootstrap state is not uploaded into the backend it creates unless a later reviewed migration is designed;
- no routine bootstrap destroy target.

Backend convention for later roots:
- partial backend block: `backend "s3" {}`;
- bucket, key, region, role ARN, encryption, and lockfile supplied at init;
- `use_lockfile=true` is mandatory;
- do not create DynamoDB solely for state locking;
- keys:
  - `aws/storage/opentofu.tfstate`
  - `aws/network/opentofu.tfstate`
  - `aws/training-node/opentofu.tfstate`
  - `aws/spot-runner/opentofu.tfstate`
- authentication uses AWS CLI `aws login` temporary credentials plus role assumption;
- no access key, secret key, token, or profile cache is passed through backend config files committed to Git.

One-use live authorization:
Authorization receipt must contain:
- authorization_id;
- account_id exactly matching the approved account;
- root exactly `tofu/aws/bootstrap`;
- region;
- bucket name;
- deployer role name and trusted administrator ARN;
- plan_sha256;
- expected add/change/destroy counts;
- max_estimated_cost;
- issued_at and expires_at;
- operator identity;
- one-use nonce.

Apply wrapper:
- verifies mode 0600;
- verifies expiry;
- verifies current caller account and ARN;
- recalculates plan hash;
- rejects any destroy count;
- writes and fsyncs a consumed marker before apply;
- never allows reuse after success or failure;
- records a non-secret receipt under artifacts/receipts/.

Code-only validation:
- tofu fmt;
- tofu init -backend=false;
- tofu validate;
- saved binary plan;
- tofu show -json piped to plan-policy validator;
- reject public access, ACL enablement, versioning off, force_destroy, missing prevent_destroy, non-TLS allowance, IAM user/access-key resources, or unexpected resource types;
- test authorization expiry, tampering, reuse, caller mismatch, account mismatch, and plan mismatch.

Human-authorized live validation:
1. Apply the exact reviewed plan.
2. Verify bucket Region, public access block, Object Ownership, versioning, encryption, TLS deny policy, tags, and no lifecycle expiration.
3. Verify no IAM access key or IAM user was created.
4. Initialize a disposable test root against `aws/backend-smoke/opentofu.tfstate` with native lockfile enabled.
5. Apply one harmless local/random resource to prove state write.
6. Attempt concurrent state-changing operations and confirm locking.
7. Inspect object versions and lockfile behavior.
8. Download a prior state version into a safe local recovery file and validate it without overwriting current state.
9. Delete only the disposable test objects and lockfile, not the bucket.

Stop condition:
After state acceptance, stop. Do not create data buckets, VPCs, IAM runtime roles, or EC2 instances in this phase.
```
