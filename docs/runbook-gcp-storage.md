# GCP storage runbook

## Code-only checks

```bash
make gcp-bootstrap-init
make gcp-bootstrap-plan
make gcp-storage-init
make gcp-storage-plan
```

`GCP_ADMIN_EMAIL` must identify the reviewed human operator. Storage planning creates no resources, but it does read the accepted remote state backend through `GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT`.

Bootstrap begins with ignored local state under `tofu/gcp/bootstrap/.bootstrap-state/`, directory mode 0700 and state mode 0600. Keep an encrypted offline backup. Do not upload bootstrap state into the bucket it creates without a separately reviewed migration.

Later roots use partial `backend "gcs" {}` blocks, bucket `example-project-tofu-state`, prefixes `gcp/storage`, `gcp/network`, and `gcp/training-node`, plus `GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT`. Never pass a credential or access token as backend configuration.

An authorized state apply must verify region, Standard class, UBLA, public-access prevention, versioning, soft delete, labels, no key creation, state write and locking, generations, and recovery. Storage apply is another gate. The old plan is invalid after any source or variable change: run `make gcp-storage-plan`, review the new plan JSON and SHA-256, then issue a mode-0600 one-use receipt bound to `ROOT=tofu/gcp/storage` and `PROFILE=storage-foundation`. Do not apply until the operator explicitly authorizes that exact plan.

After an accepted apply, upload only a tiny fixture. The uploader creates data objects and the manifest first, verifies size, CRC32C, and SHA-256 metadata, and creates `COMMITTED.json` last. Test trainer read, trainer delete/overwrite denial on Bronze/Silver, artifact creation, anonymous-read denial, and restoration of a disposable soft-deleted fixture object. Record an inventory and cost estimate. Do not upload real datasets in Goals 03–04.

Before any fixture write, inspect each bucket IAM policy and confirm the default `projectOwner`, `projectEditor`, and `projectViewer` convenience principals are absent from all four legacy Storage roles. UBLA disables ACL evaluation, but it does not by itself remove these bucket-level legacy IAM grants. Confirm the artifact lifecycle prefixes are exactly `artifacts/tmp/` and `artifacts/runs/unaccepted/`, consistent with the required object layout.

The fixture uploader is mutation-gated and uses generation-match zero for every object, manifest, and final commit marker:

```bash
python3 scripts/gcp/snapshot_manifest.py build --root fixture --manifest fixture-manifest.json
python3 scripts/gcp/upload_snapshot.py --execute --layer bronze --bucket "$GCP_BRONZE_BUCKET" --root fixture --manifest fixture-manifest.json --impersonate-service-account "$GCP_DATA_PUBLISHER_SERVICE_ACCOUNT"
```

The command is deliberately bound to the exact fixed layer bucket and the keyless `data-publisher` identity. A mismatched bucket or identity is rejected before invoking `gcloud`. Re-running against existing objects fails the generation precondition instead of overwriting.

Create-only artifact uploads use the native JSON API because `gcloud storage cp` performs a destination metadata read that is incompatible with the intentionally create-only training identity:

```bash
python3 scripts/gcp/upload_artifact.py --execute --file config.json --object artifacts/runs/<run_id>/config.json --impersonate-service-account "$GCP_TRAINING_SERVICE_ACCOUNT"
```

The uploader captures the short-lived impersonated token in memory, never prints it, binds the destination to the fixed artifact bucket and run prefix, uses `ifGenerationMatch=0`, and verifies returned size and CRC32C.

## Goal 04 stop gate

Code validation and a policy-accepted plan are not permission to apply. Stop with `UNTESTABLE` for bucket controls and fixture behavior until a new exact-plan authorization is supplied. There is no routine persistent-storage destroy target.

Persistent teardown has no routine Make target. Follow a reviewed break-glass change with inventory, backup, retention review, and explicit resource-by-resource authorization.
