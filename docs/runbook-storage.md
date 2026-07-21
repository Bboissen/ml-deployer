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
- Workers: set `TF_VAR_vpc_uuid` and `TF_VAR_vpc_cidr` to the storage root's exact outputs after an authorized apply. The worker derives the VPC-local resolver from that CIDR.

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

## Phase 2: storage/cache smoke build

Install the pinned dependencies, then run the single offline acceptance entrypoint:

```bash
make venv
make storage-phase2-selftest
```

It generates the tiny deterministic pack twice and checks byte identity; canonical manifest/pack hashes; traversal, duplicate, mutation, extra, and truncation rejection; injected cold fetch followed by plan deletion and network-free warm verification; disk, lock, and eviction safety; explicit fake-credential SigV4 client configuration without a request; private signed-plan files; size/cost and one-use authorization fixtures; cleanup rendering; and network/Ray ambiguity and public-route rejection fixtures.

The full builder is pinned to `pyarrow==24.0.0`. Its full profile targets exactly 536,870,912 object bytes across exactly 16 deterministic partitioned Parquet objects with a one-percent tolerance. `test_pack_hash` hashes a canonical descriptor containing protocol, builder, pinned PyArrow version, and ordered exact object paths/sizes/SHA-256 values. `manifest_sha256` separately hashes the exact canonical manifest bytes. Canonical JSON is UTF-8, sorted-key compact JSON with exactly one trailing LF.

The cache authority is the expected pack hash plus manifest SHA-256 delivered outside the signed plan. Cold staging uses global-management and per-entry `fcntl` locks, a same-filesystem unique `.partial` directory, sequential bounded downloads, exact membership/size/hash checks, file and directory fsyncs, an atomically written `.ready` binding both hashes, atomic rename, and parent fsync. Existing entries are fully reverified. Oldest-ready-first eviction never selects the current, incomplete, symlinked, or locked entry. Warm verification accepts no plan, URL, fetcher, or credentials.

Required free disk is enforced as:

```text
ceil(1.2 * (snapshot bytes + largest temporary object + configured Ray spill/workspace bytes))
```

This prerequisite intentionally exposes no live Make target. `scripts/storage/phase2.py` provides `build-pack`, non-executing `dry-run`, and an exact-flag-gated `live-smoke`; `scripts/storage/phase2_worker.py` provides cold, warm, and network worker commands. Build the full pack twice into distinct roots; `live-smoke` requires both receipts and verifies their parsed manifests, object hashes, object counts, and byte totals match before any live action. Passing the selftest proves only the tiny builder and ordered dry-run path: it does not contact DigitalOcean/Spaces, arm systemd, apply/destroy resources, transfer a signed plan, or prove real routing/Ray identity. Phase 2 remains **not ready for live execution** until this executable path passes separate adversarial review and its cleanup arming, secure transfer/removal, cloud identity, cache, network, Ray, and destroy receipts are proven live.

## Phase 2 live-execution contract

The live sequence is fixed: consume the one-use authorization and prove a fresh empty isolated workspace; publish and HEAD/list verify the pack; immediately query `/v2/sizes`; arm and verify independent cleanup; apply exactly once; discover the worker; generate and securely transfer the plan; run cold cache; delete the plan locally and remotely; run warm verification with zero network; collect network/Ray evidence; fully destroy the isolated workspace and verify zero managed resources; then disarm cleanup and remove the workspace. Any error leaves cleanup armed. Apply is never automatically retried.

Before any paid action, query `/v2/sizes` and verify the live price and AMS3 availability for `s-1vcpu-1gb`. The smoke uses one 25 GiB Droplet, a maximum of 20 minutes from apply through verified destroy, and an initial authorization cap of $5.10 including the Spaces base subscription, prior authorized spend, and compute conservatively rounded to a full billing hour. Stop for human review between smoke phases.

The test pack is 512 MiB within the frozen one-percent tolerance, with exactly 16 partitioned Parquet objects plus a SHA-256 manifest under `smoke/<test-pack-hash>/`. Two independent pack generations must produce byte-identical objects, manifest bytes, and hashes.

Cache materialization requires a disk-space preflight, an inter-process lock, `.partial` staging, per-object size and SHA-256 verification, atomic final rename, a `.ready` marker bound to the exact manifest hash, a cache-size ceiling, and cleanup policy. The warm-cache test removes the signed download plan before reuse and must prove no storage access is required.

Every machine-readable Droplet receipt records:

- VPC ID, Droplet ID, and Ray node ID.
- Resolver configuration and the resolved Spaces endpoint addresses.
- VPC CIDR plus route and source-interface evidence for the resolved address.

Discover the interface from the VPC CIDR, resolved address, and kernel route. Never assume `eth1`. A public-looking regional Spaces DNS answer does not disprove internal transport; same-region routing must be demonstrated by the route/source evidence.

Each field is grouped as expected, controller-observed, or worker-observed and carries a source description. The controller cross-checks the selected Terraform VPC and Droplet ID against the DigitalOcean API. The worker discovers the metadata-private interface by matching its metadata address to `ip -j address`; records metadata address/gateway/netmask, `systemd-resolved` effective link/upstreams and `/etc/resolv.conf`; resolves the exact virtual-hosted AMS3 endpoint; and records `ip -j route get` for every answer plus the expected VPC route. Every download-eligible answer must select the metadata-private interface and source. Ray identity must uniquely match one alive node by worker hostname plus Tailscale IP; the DigitalOcean private IP is forbidden as the Ray identity.

Cleanup is an absolute-deadline, initiating-shell-independent service scoped to the unique `smoke-<run-id>` workspace. It performs a full destroy without `-target`, retries cleanup only, writes a durable success/error receipt, and may be disarmed only after state lists zero managed resources. The workspace must be freshly created, proven not to preexist, and removed only after successful cleanup. Rendered cleanup validation is offline; arming remains a human gate.

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
