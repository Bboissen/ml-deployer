# Toolbox and workspace contract

Status: shared interface 2.0.0, toolbox profile and offline acceptance implemented;
provider launch/access/storage/deadline implementation remains pending.
See [the executable interface](../../docs/workspace.md). Applies independently
to [AWS](02_AWS.md), [GCP](03_GCP.md) and [Azure](04_AZURE.md).

## User journey

1. Select provider, account scope, region, workspace name, CPU/memory/disk profile,
   maximum lifetime, storage ownership/access and the authorized operator.
2. Check identity, quota, image, network, storage and state; review a saved plan.
3. Launch the workspace through that exact authorized plan, then check readiness.
4. Open its documented terminal session, clone the external ML repo at a chosen
   revision, create its environment and install its locked dependencies.
5. Use the native bucket URI through SDK/CLI or explicit local staging. The ML
   repo starts its own work and saves anything durable to object storage.
6. Disconnect, inspect, stop or destroy compute through documented operations;
   persistent data remains. Relaunch and reuse the bucket without re-uploading it.

Proposed verbs are `doctor`, `plan`, `launch`, `status`, `connect`, `storage` and
`destroy`. Final command names are an implementation decision. One invocation
selects exactly one provider; none deploys or coordinates all clouds. Provisioning
must never silently clone or execute an arbitrary ML project as root.

## Toolbox

Provide a reproducible Linux CPU environment with Git, a documented supported
Python runtime, virtual environments, a locked dependency installer, build tools
needed by the supported Python profile, and that provider's storage CLI/SDK.
Use a pinned OS/toolbox image or reviewed versioned bootstrap manifest. Publish
the installed versions and supported CPU/memory/disk facts in readiness output.

Project environments are writable and isolated from the toolbox environment.
Test installation from an ordinary project's dependency lock. Do not impose the
old scientific mega-image or its Python version on every project. Container
runtime support can be a declared toolbox capability; GPU/CUDA, distributed
execution and framework-specific images require separate named acceptance.

## Storage and identity handoff

- Create private persistent workload storage, encrypted and recoverable. State
  storage remains separate and is not readable by the workspace identity.
- Publish non-secret provider, account/region, workspace ID, data URI, permitted
  output URI/prefix and identity-selection information in a stable handoff.
- Describe native URI/version semantics and supported SDK authentication. A
  bucket URI is not a mounted filesystem. Staging must be explicit and bounded.
- Scope dataset reads and output writes to the reviewed bucket/container/prefix.
  Support multiple objects and ordinary project-selected paths, not a fixed
  synthetic input. Uploading/adopting actual data is a separate ownership gate.
- Use instance roles, service accounts or managed identities. Do not embed cloud
  keys, SAS tokens, registry passwords or Git secrets in image/state/bootstrap.
- Generic storage copy/list/download operations are infrastructure utilities.
  Dataset generation, validation, transformation and ML outputs belong outside.

## Session, deadline and persistence

Provide an authenticated terminal route to the machine without internet-wide
SSH rules or a home relay. Name exact permitted operators and any additional
network/service cost. A management-command API alone is not interactive access.
If notebook access is supported, document a private tunnel; do not expose a
public unauthenticated notebook.

The workspace remains available until explicit teardown or its absolute maximum
lifetime, independently of whether a training command finishes or a terminal
disconnects. An independent provider-side guard must cover failed bootstrap,
failed schedule creation and partial apply. Idle shutdown is optional and cannot
replace that guard. Report stopped, deallocated, deleted and still-billable
resources accurately. Never promise zero cost while retained resources exist.

Workspace disks are disposable by default. No automatic checkpoint/result sync
is implied; the external project/operator saves durable files to its bucket.
Any persistent disk option needs explicit ownership, cost and teardown behavior.

## Acceptance boundary

Readiness proves tools, terminal access, native identity, storage access, profile
facts and deadline coverage. It does not prove that an ML run succeeded. Retain
infrastructure evidence without requiring workload-written receipts, model
metrics, a result-manifest format or a separate ML completion publisher.

Keep one small deterministic data-science example: install locked NumPy/pandas
in a test environment, fetch a tiny CSV from an isolated native-bucket test
prefix, and check four values `1, 2, 3, 4` produce count `4`, sum `10` and mean
`2.5`. Upload a stable JSON result and read it back to check its exact values and
bytes. Pin the fixture, dependencies and expected output; use no random input,
model training, HPO or tracking service. Verify repeat execution gives the same
result, including after bucket reuse by a second workspace.

Share the small example source and expected result, but execute and accept it
independently on each provider. No inter-cloud comparison service, synchronized
run or identical VM image is required. A reviewed acceptance upload is separate
from bucket provisioning, which starts empty. Failure must report whether tools,
dependencies, identity, download, calculation or upload failed. Do not automatically
delete test evidence or turn this example into the external project's ML contract.

Each provider separately demonstrates: empty bucket creation; connection and
external repo clone; isolated dependency setup; authorized small multi-object
read/write using its native storage; denied state/unrelated-data access; terminal
disconnect/reconnect; bounded expiry and partial-failure handling; complete
workspace teardown; bucket survival and reuse by a second workspace; the small
deterministic example. No production training or coordination with another
provider is required to accept the toolbox.
