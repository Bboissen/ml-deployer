# One reviewed AWS Deploy (M6)

Use the short JSON configuration from `infra/aws/project.example.json` with the
workstation installer from PR28. Run from the installed repository:

```sh
scripts/aws/workspace.sh project.json deploy
scripts/aws/workspace.sh project.json deploy --authorization 'Approve the displayed account, resources, transfer, cost and lifetime scope'
scripts/aws/workspace.sh project.json status --wait 30
scripts/aws/workspace.sh project.json logs
scripts/aws/workspace.sh project.json cancel
scripts/aws/workspace.sh project.json resume
```

The first Deploy performs read-only authentication, exact Git ref resolution,
source hashing, retained-state ownership checks and RAM/quota/price discovery.
It saves a concrete immutable scope and selects its operation automatically.
Authorization binds the displayed scope, generated inputs and source. It then
binds every inspected immutable OpenTofu plan to that authorization; routine
foundation, access, prepare, launch and teardown stages need no repeated prompt.
A changed configuration/source requires another review. `--operation` can select
an earlier operation explicitly; operators need not copy state paths or hashes.
Configuration paths are resolved before the CLI changes its working directory.

The ordered stages are artifacts, state/bootstrap and platform, optional private
repository access, ingestion, guarded preparation, one launch, non-root setup/run,
output verification, compute teardown and a second output verification. Completed
immutable manifests may be reused only after exact native object versions and
SHA256 hashes are read again. Generic outcomes report infrastructure, setup, job,
output persistence and cleanup separately. Workspace mode executes setup and
retains compute until cancel or provider expiry; job mode runs setup and entrypoint
on every Deploy.

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
it never registers another key silently. An uncertain access/retirement apply
without a verifiable success receipt stops for ownership reconciliation.

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
refusal, repeated recovery bindings, original-create ownership scopes and legacy
engine compatibility. These are mocked cloud checks, not native acceptance.

Clean Linux/macOS installations, real IAM propagation, encrypted SNS delivery,
private-key onboarding, output transfer and expiry under controller loss require
an authorized native campaign. The alert topic uses a retained rotating customer
KMS key and scoped CloudWatch publisher permissions, as required by the
[AWS SNS encryption documentation](https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html).
Compute quotes exclude retained storage, KMS, public IPv4, request/transfer and
observability costs; the review lists these separately and is not a spending cap.
