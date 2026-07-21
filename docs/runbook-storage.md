# Runbook: persistent Spaces and disposable worker caches

## Scope and invariants

`terraform/digitalocean-storage` owns exactly three persistent resources in `ams3`: one named VPC, one private infrastructure-state bucket, and one private Demo Bronze bucket. It has an independent state lifecycle from `terraform/digitalocean-workers`. Destroying Ray workers must leave all three persistent resources intact.

The Bronze bucket layout is:

```text
smoke/<test-pack-hash>/
bronze/snapshots/<accepted-content-hash>/
```

Silver and later data layers are out of scope and require a new reviewed phase.

Worker-local cache entries live at `/data/demo-cache/<snapshot-hash>/`. No dedicated storage Droplet is used.

Phase 1 is code-only. Do not run an apply, activate or migrate a backend, create or revoke credentials, run a paid smoke, or decommission anything during this phase.

## Environment-only configuration

Copy `.env.example` to the ignored `.env` and set values locally. Never put secrets in Terraform variables, state outputs, backend files, command arguments, logs, cloud-init, or Git.

- Bootstrap/provider: `DIGITALOCEAN_TOKEN`, `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY` use a temporary broad identity.
- Later S3 backend: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` use a separate state-bucket-scoped identity. Never map or reuse the broad provider key for this role.
- Bronze access uses a separate Bronze-bucket-scoped identity.
- Non-secret inputs: `TF_VAR_state_bucket_name`, `TF_VAR_bronze_bucket_name`, `TF_VAR_vpc_name`.
- Workers: set `TF_VAR_vpc_uuid` to the storage root's exact `vpc_uuid` output after an authorized apply.

## Phase 1: non-creating checks

```bash
make storage-init
make storage-validate
make storage-plan
```

`storage-init` always initializes with `-backend=false`. `storage-validate` checks formatting, configuration, all three source-level `prevent_destroy` guards, and parses `backend.tf.example` in a temporary minimal root without contacting a backend. `storage-plan` uses a temporary plan and JSON file, cleans both on exit, and requires exactly three creates with the approved VPC, bucket, versioning, privacy, and lifecycle semantics.

The state bucket has versioning but no expiration. The Bronze bucket expires current `smoke/` objects after 7 days, noncurrent smoke versions after 90 days, and aborts incomplete multipart uploads after 7 days. Bronze snapshots never expire automatically.

There is no `storage-down` target. `force_destroy = false` and `lifecycle.prevent_destroy = true` protect the persistent resources during normal configuration changes. However, Terraform cannot enforce `prevent_destroy` after its resource block is removed from configuration; deletion still requires the break-glass gate below.

## Human gate: initial bootstrap apply

Stop after reviewing the Phase 1 semantic plan. Immediately before an authorized apply, recheck account context, globally unique bucket names, AMS3 availability, current pricing, and the plan's exact three creates. The authorization must name the plan and persistent billing commitment. Phase 1 does not authorize this operation.

After apply, record the state and Bronze bucket names/endpoints and VPC UUID/name/region. The storage output is authoritative: pass its exact VPC UUID to the worker root. Name lookup, remote-state coupling, and sentinel UUIDs are forbidden for live workers. Create and verify separate state-bucket-scoped backend and Bronze-bucket-scoped identities before proposing revocation of the broad bootstrap identity.

## Human gate: backend activation and migration

The initial storage root intentionally has no active backend. `backend.tf.example` uses the DigitalOcean-supported S3-compatible AMS3 endpoint, `us-east-1`, AWS compatibility skip flags, `use_lockfile = true`, and key `ray-terraform/storage/terraform.tfstate`. A future worker backend must use a distinct key such as `ray-terraform/workers/terraform.tfstate`.

Activation is a separate reviewed commit. Before migration:

1. Preserve the local state and checksum in protected local storage; treat both as secret-bearing.
2. Copy the inactive example to `backend.tf`, substitute only the reviewed state bucket name, and review the diff.
3. Export the separately verified, state-bucket-scoped backend credentials only through `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; never reuse the broad bootstrap/provider key.
4. At a human gate, run `init -migrate-state`; never pass credentials with `-backend-config`.
5. Verify `state list`, a non-refreshing plan, and the expected remote state object before considering migration accepted.
6. Retain the local state backup on any failure. Remove it only after remote state and locking are independently verified.

Backend syntax and `use_lockfile = true` do not prove Spaces locking works. Run this human-gated contention probe before accepting migration:

1. In process A, start an interactive, no-change apply and leave it waiting while it holds the state lock.
2. In process B, run a plan against the same key with `-lock-timeout=0s`; it must fail with lock ownership evidence.
3. Answer `no` in process A, then rerun process B; it must acquire the lock and complete.
4. Confirm no stale `.tflock` object remains. If any step differs, reject the migration and retain local state.

After the state-bucket-scoped and Bronze-bucket-scoped identities are verified against only their intended bucket operations, revocation of the broad bootstrap key is another human-gated action. Confirm both scoped identities still work after revocation.

## Phase 2 contract: bounded storage/cache smoke

Before any paid action, query `/v2/sizes` and verify the live price and AMS3 availability for `s-1vcpu-1gb`. The smoke uses one 25 GiB Droplet, a maximum of 20 minutes per smoke phase, and an initial authorization cap of $5.10 including the Spaces base subscription and compute smoke. Stop for human review between smoke phases.

The test pack is approximately 512 MiB, roughly 16 partitioned Parquet objects plus a SHA-256 manifest under `smoke/<test-pack-hash>/`. Before paid smoke, finalize a numeric size tolerance. Two independent pack generations must produce byte-identical objects, manifest bytes, and hashes.

Cache materialization requires a disk-space preflight, an inter-process lock, `.partial` staging, per-object size and SHA-256 verification, atomic final rename, a `.ready` marker bound to the exact manifest hash, a cache-size ceiling, and cleanup policy. The warm-cache test removes the signed download plan before reuse and must prove no storage access is required.

Every machine-readable Droplet receipt records:

- VPC ID, Droplet ID, and Ray node ID.
- Resolver configuration and the resolved Spaces endpoint addresses.
- VPC CIDR plus route and source-interface evidence for the resolved address.

Discover the interface from the VPC CIDR, resolved address, and kernel route. Never assume `eth1`. A public-looking regional Spaces DNS answer does not disprove internal transport; same-region routing must be demonstrated by the route/source evidence.

The 512 MiB test proves the protocol, not 50 GiB production performance. Full staging capacity uses:

```text
required disk = snapshot bytes
              + largest temporary object
              + Ray spill/workspace allowance
              + at least 20% safety headroom
```

## Human gate: break-glass decommission

Persistent decommission is deliberate and has no Make target:

1. Preserve and verify readable Terraform state; inventory the VPC and every current object, noncurrent version, delete marker, and incomplete multipart upload.
2. Revoke or disable all producers, consumers, presigned-plan issuers, and backend users.
3. Review a dedicated change that removes `prevent_destroy`; do not remove resource blocks first.
4. Obtain explicit approval for the named buckets/VPC, retained-data disposition, and billing impact.
5. Deliberately remove current objects, versions, delete markers, and multipart uploads, then plan and delete only the approved resources.
6. Verify state, Spaces listings, VPC dependencies, and the DigitalOcean billing/dashboard view. Record final confirmation before closing decommission.
