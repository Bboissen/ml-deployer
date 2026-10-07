# Workspace interface 2.0.0

Implemented: offline records, validation, local toolbox probing and the bounded
acceptance example. Provider provisioning, authentication, interactive access and
deadline guards are pending in the [independent provider tasks](../goal/workspace/05_FOUNDATION_AND_HANDOFF.md).
The operator connects, clones an external ML repository and installs that
repository's dependencies. Infrastructure does not execute or grade production ML.

## Records and version policy

The closed [JSON schema](../shared/workspace/schema.json) has three record kinds.
All require `schema_version: "2.0.0"`, exactly one provider, account scope, region
and a 3–48-character workspace ID. Unknown fields, credentials, model settings,
image/run-spec requirements and publisher fields are rejected in requests.
Version 2.0.0 is a separate interface, not an in-place revision of batch 1.0.0.
Breaking field/semantic changes require a new major version and reviewed caller
migration. New fields require a versioned schema change; nothing is silently
ignored. Keep old contracts/validators, original receipts and saved plans intact
until each provider migration is reviewed. PR18/19's input-version variant must
not be rewritten into main's older batch contract or workspace acceptance.

| Kind | Producer and consumer | Required behavior |
| --- | --- | --- |
| `request` | Operator → provider planner | Explicit CPU/memory/disk minimums, toolbox profile, named operators, 15–720-minute maximum runtime, native data/output prefixes and separate state URI. No cloud action follows from validation. |
| `handoff` | Provider → operator and readiness collector | Exact request hash/scope/storage, immutable image reference/bootstrap hash, machine ID, non-root user/project directory, native identity selector, interactive terminal argv and absolute lifetime/guard facts. |
| `readiness` | Provider collector → operator | Exact request/handoff hashes and scope, observed capacities/tool versions, timestamp and all nine check statuses with provider/workspace-scoped local evidence paths. Failed/unverified checks cannot pass `--require-ready`. |

Canonical bytes are UTF-8 JSON with sorted keys, compact separators, unescaped
Unicode and one trailing newline. SHA-256 includes that newline. The validator
prints those bytes for the final validated record. Do not hash pretty JSON or a
Terraform output wrapper as the record. Producer fields and schemas are closed;
duplicate keys and nonfinite JSON are rejected.

Install the small locked test/validation environment once (package download,
separate from routine checks), then run entirely offline checks:

```bash
make workspace-test-setup
make check
make historical-check
```

`workspace-test-setup` requires uv and Python 3.13 (uv can obtain the runtime).
It creates only `.tools/workspace-venv/` and uses hash-verified binary packages.
`WORKSPACE_PYTHON` may select an already installed equivalent environment.
The workspace lock includes NumPy/pandas and JSON-schema tooling; cloud SDKs
remain provider-owned. `historical-check` explicitly checks the preserved batch
contracts/demo tooling; they are not prerequisites of the workspace interface.
OpenTofu scaffold initialization disables backends but may download locked
providers from registries; it does not query cloud accounts.

```bash
.tools/workspace-venv/bin/python scripts/workspace/validate.py request.json
.tools/workspace-venv/bin/python scripts/workspace/validate.py request.json \
  --handoff handoff.json --readiness readiness.json --require-ready
```

The [fixtures](../shared/workspace/fixtures/aws-request.json) are simulated
specimens with invented resource/tool/guard facts, not deployment inputs or live
readiness evidence. Validation checks record consistency at `observed_at`; it
does not establish current readiness or verify cloud assertions. Provider
collectors must capture actual tool/session/API/negative-access/guard evidence
and refresh it before use. Terminal argv is data, never executed by shared code.
Providers validate exact target/operator/region/account arguments themselves.

## Toolbox and readiness

The [toolbox profile](../shared/workspace/toolbox.json) is Linux x86_64 CPU with
Python 3.13, venv, Git, uv, cc and make. Each provider pins its immutable OS image,
versioned bootstrap and native CLI/SDK; no common OCI image/registry is required.
Report installed versions. Project environments are writable by a non-root user
and separate from toolbox dependencies. Containers are optional; GPU/distributed
execution and notebook services are outside this profile.

`scripts/workspace/probe-toolbox.py PROVIDER PROJECT_DIRECTORY` gathers read-only
local tool/SDK versions, OS/architecture, CPU/memory/filesystem capacity, venv and
non-root/writable-directory facts. It reports missing tools and exits 2 if local
toolbox checks fail. It leaves terminal, identity, storage, denied state/unrelated
access and deadline checks explicitly unverified. Providers must implement those
checks separately; a successful local probe cannot mark a workspace ready.

The nine readiness checks are `toolbox`, `terminal`, `identity`, `storage`,
`state_denied`, `unrelated_denied`, `profile`, `deadline`, `writable_project`.
Evidence paths start `evidence/<provider>/<workspace_id>/`. Preserve actual
evidence there. The deadline check must prove a provider-side guard active before
or at compute creation, absolute expiry within the maximum, failed-bootstrap and
partial-apply protection. A guest timeout or later-created schedule is insufficient.
Azure deallocation still leaves retained resources/costs; report them explicitly.

## Native storage handoff and bounded example

`data_uri` and `output_uri` are distinct reviewed native prefixes ending in `/`.
State is a different S3/GCS bucket or Azure storage account. Workload identities
must not read state. Requests do not upload content; new workload buckets start
empty, and existing content needs adoption review. Paths are not filesystem mounts.
This minimal interface rejects signed/query URIs, userinfo, ports, percent-encoded
paths, traversal and overlapping read/write prefixes. Broader URI support needs a
versioned review. Output prefixes remain provider-enforced per-workspace grants.

AWS uses instance-role credentials and S3 object version IDs; GCP uses keyless
service-account credentials and GCS generations; Azure uses a selected managed
identity client ID, Entra auth and Blob versions/ETags. Azure selection is not a
SAS token. SDK/CLI adapters and transfer/version evidence are provider-specific;
no common S3 gateway or cross-provider transfer is implemented.

The exception to external ML ownership is one [acceptance example](../shared/workspace/example/example.py):

1. Separately review a tiny fixture upload into an isolated test prefix. The
   checked-in `fixture.csv` is exactly `value` then `1, 2, 3, 4`; pin its checksum.
2. Provider adapter fetches the exact object version with native identity and a
   128-byte bound. Save URI, version/generation/ETag, hash and identity evidence.
3. In an isolated locked environment run `example.py calculate INPUT OUTPUT`.
   It verifies fixture bytes, computes count 4/sum 10/mean 2.5 with NumPy/pandas,
   and creates stable `{"count":4,"mean":2.5,"sum":10}` JSON plus a newline.
4. Provider adapter uploads those bytes to the permitted test output prefix,
   records the immutable returned version, then retrieves that version with the
   same size bound. Run `example.py verify OUTPUT RETRIEVED` for exact-byte checks.
5. Repeat in the same workspace and after a second workspace reuses the retained
   bucket. Preserve evidence; do not automatically delete objects.

The shared example never talks to a cloud, creates data remotely or deletes
evidence. Offline tests simulate only transfer/persistence with local copies.
Provider tests must distinguish dependency, identity, download, calculation,
upload and retrieval failures. No training, HPO, tracking service, production
dataset schema, ML result manifest or trusted publisher is involved.
