# One reviewed AWS deployment

Use the short JSON configuration from `infra/aws/project.example.json` with the
workstation setup described in the [quickstart](aws-deployer-quickstart.md).
From a source checkout:

```sh
./workspace project.json                       # review, one interactive confirmation, then Deploy
./workspace project.json --authorization "approve scope HASH"   # HASH: the 16 characters the review printed
./workspace project.json status --wait 30
./workspace project.json logs
./workspace project.json cancel
./workspace project.json resume
```

A Deploy without `--authorization` prints the readable scope (account, zone,
repository commit, dataset bytes, machine and price estimate, lifetime, retained
resources, excluded fees) and asks once in an interactive terminal; typing
`deploy` records an authorization bound to that exact scope hash. Without a
terminal it stops at `review_required` and prints the hash; a later
`--authorization` must contain that hash, so no caller can approve a scope it
has not seen. Stage progress and a plain outcome
summary with the next command go to stderr; stdout stays JSON for automation.
The first Deploy performs read-only authentication, exact Git ref resolution,
source hashing, retained-state ownership checks and RAM/quota/price discovery.
A retained foundation keeps its existing subnet zone. The review includes any
required removal of the deployer's former operator-management permissions.
It saves a concrete immutable scope and selects its operation automatically.
Authorization binds the displayed scope, generated inputs and source. It then
binds every inspected immutable OpenTofu plan to that authorization; routine
foundation, access, prepare, launch and teardown stages need no repeated prompt.
A changed configuration/source requires another review. `--operation` can select
an earlier operation explicitly; operators need not copy state paths or hashes.
Configuration paths are resolved before the CLI changes its working directory.
To run several job-mode project files in order with one review, see
[batch](aws-batch.md).

The ordered stages are artifacts, state/bootstrap and platform, any reviewed
retained IAM update, optional private repository access, ingestion, guarded
preparation, one launch, guest dataset staging, non-root setup/run, output
verification, compute teardown
and a second output verification. Completed
immutable manifests may be reused only after exact native object versions and
SHA256 hashes are read again. Generic outcomes report infrastructure, setup, job,
output persistence and cleanup separately. Workspace mode executes setup and
retains compute until cancel or provider expiry; job mode runs setup and entrypoint
on every Deploy.

Launch planning initializes OpenTofu before observing the guard and requires a
heartbeat at most 30 seconds old, waiting only within a bounded readiness check.
Apply initializes before its final native checks and requires both saved timestamps
to have at least 30 seconds remaining in the two-minute admission window. A fresh
live heartbeat never substitutes for the heartbeat embedded in the immutable plan.
Expired evidence is rejected before consuming launch authorization; the OpenTofu
precondition still enforces the full two-minute limit at resource admission.

New deployments open their fixed five-minute launch window when runner preparation
begins, then launch as soon as preparation and native readiness checks pass.
There is no additional five-minute scheduling buffer. The deadline schedule must
exist before the launch role can launch: its native creation time is checked
against the later of the lease opening and the role's creation time. The role's
unique ID and creation time must match the saved preparation state. Provider-side
expiry stays fixed, including time spent preparing; slow preparation cannot
extend the window or the maximum lifetime. Previously saved future leases retain
their original opening time.

The controller reuses verified SDK clients within each identity and service to
reuse connections. Every guard, IAM, state and output observation remains a fresh
API request. Cleanup reports its start before waiting for AWS deletion, then its
result and the second output verification.

## Controller loss and ownership

A POSIX lock excludes concurrent controllers for the same project prefix. A
workspace ownership record rejects another operation until safe cleanup. Stage
intents and results are fsynced in an immutable numbered hash chain; the current
status/index is replaced atomically. All plans, authorizations and state remain
under ignored `evidence/`; journal/log output excludes credentials.

Resume reconciles consumed bootstrap/platform plans against exact owned state
lineage, resource identities and the original create scope. Each recovery plan
has a new immutable directory. Interrupted ingestion aborts only exact unique
operation-owned multipart keys before a fresh attempt or sealed-manifest reuse.
A secret-creation timeout can recover an exact registered read-only deploy key
and native secret version. If the private key disappeared before secret creation,
resume stops and records the exact public key for separately reviewed revocation;
it never registers another key silently.

Interrupted IAM migration or credential-access applies use a fresh recovery plan
for the original policy changes. Recovery checks the original authorization,
state lineage, complete retained resource ownership and unchanged non-policy
attributes. Each policy must match its original before or after value; recovery
can finish those updates or record that they already completed. It cannot create
or delete resources, replay a consumed plan, or adopt unrelated policy drift.
The exact live policies are read again before apply, so changes outside OpenTofu
also stop a stale saved plan. A plan the planner refused never gets a review or
an apply receipt; resume reports it and settles the operation as a failure
without recovery, so a new review can follow. Repeated interruptions preserve the entire recovery chain. An uncertain
retirement apply without a verifiable success receipt still stops for ownership
reconciliation.

If retirement succeeded but its source fingerprint is no longer accepted, cleanup
uses the original consumed launch plan as its recovery reference. It verifies that
plan's source and authorization, current state lineage, owned resource identities
and compute absence before deleting runner controls. It preserves the retirement
receipt, never repeats the job or launch, and verifies the same saved output
versions after cleanup. This also covers a checkout changing between retirement
and cleanup; source checks for pending saved applies remain exact.

Once launch started, resume never repeats RunInstances or SendCommand. It checks
for durable results and performs owned teardown. Cancel records an intent even
when a worker holds the lock. Workers check it between stages and during bounded
transfer/SSM polling; a running OpenTofu call remains bounded by its timeout.
After controller loss or cleanup uncertainty, provider-side expiry stays armed.
Runner controls cannot be deleted until native compute/disk/interface absence is
verified. A local lock cannot coordinate different hosts; use one workstation
with its preserved evidence directory. Remote OpenTofu locking still protects
state, but is not a cross-host operation coordinator.

## Validation and native gaps

Offline tests cover short-config stage ordering, transfer-before-compute, teardown,
workspace retention, cancellation, lock exclusion, journal drift, consumed launch
refusal, repeated recovery bindings, reviewed IAM tightening, exact access-policy
recovery, retained-zone selection, original-create ownership scopes and legacy
engine compatibility. These are mocked cloud checks, not native acceptance.

Clean Linux/macOS installations, real IAM propagation, encrypted SNS delivery,
private-key onboarding, output transfer and expiry under controller loss require
an authorized native campaign. The alert topic uses a retained rotating customer
KMS key and scoped CloudWatch publisher permissions, as required by the
[AWS SNS encryption documentation](https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html).
Compute quotes exclude retained storage, KMS, public IPv4, request/transfer and
observability costs; the review lists these separately and is not a spending cap.
