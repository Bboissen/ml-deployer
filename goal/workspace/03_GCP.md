# Google Cloud ML workspace goals

Status: target accepted; implementation/live acceptance pending. Follow the
[scope](00_SCOPE_AND_CLEANUP.md) and [toolbox contract](01_TOOLBOX_CONTRACT.md).
GCP works independently of AWS, Azure and the homelab.

## A. Reconcile existing state and leftovers

Refresh project/region/zone, APIs, quota, images, IAM, storage and compute inventory.
The October audit found no VMs/disks/reserved addresses, but initial and r4 dummy
deployments retained two deletion jobs, four identities and two stale managed
states. Prepare separately reviewed runner-only reconciliation; preserve empty
r2/r3/default states and the persistent platform. Recheck before any mutation.

Classify old artifacts/bronze/silver buckets, data-publisher/training-runtime
identities, default network and legacy state as adopt, retain or decommission.
Old bucket contents were inaccessible in the audit; do not assume emptiness.
Retain useful PR18/19 fixes but replace fixed synthetic paths, output grading,
mandatory Artifact Registry mirroring and the ML publisher lifecycle.

Acceptance: each existing resource has a verified owner/state and disposition;
an exact cleanup plan precedes any destroy. Stop for review.

## B. Persistent GCS and keyless access

Keep protected state GCS separate from generic private workload GCS. Create empty
storage with uniform access, public-access prevention and versioning/recovery.
Publish native `gs://` locations and google-cloud-storage/gcloud usage, including
GCS object generations. Do not present GCS as an S3-compatible endpoint.

Use a workspace-specific keyless service account and scoped bucket/prefix grants.
Remove `fixtures/tool-complete-dummy/<hash>.parquet` from generic runner/startup
requirements. Support arbitrary reviewed project dataset paths and multiple
objects. Verify inherited project/folder grants do not override intended limits.

Acceptance: authorized native reads/writes work, state/unrelated storage and other
workspace outputs are denied, and workspace teardown retains workload storage.

## C. Interactive Compute Engine toolbox

Use a supported Linux image that can provide writable project environments and
the agreed tools; review whether the existing container-oriented COS bootstrap
should be replaced for this workflow. Preserve useful temporary-credential and
bootstrap filesystem fixes. Verify actual machine CPU/memory/disk facts.

Enable [IAP SSH](https://docs.cloud.google.com/compute/docs/connect/ssh-using-iap)
and OS Login for exact reviewed operators. Scope the necessary firewall/IAM
rules; do not open internet-wide SSH or require a home tunnel. Document the
connect command and Git/package egress. Clone an independent repo at a revision,
install its lock in an isolated environment, and use its native GCS handoff.

Acceptance: named-operator connection/reconnection and clone/install/storage work;
toolbox readiness does not run the old conformance workload or shut down on exit.

## D. Native deadline and full reconciliation

Retain and verify a creation-time native VM maximum duration with an appropriate
termination action. Preserve an independent guard as needed; a failed Scheduler
creation or startup must not remove the native cap. Handle session disconnect
without extending the absolute lifetime. Test partial apply and stale state.

Destroy workspace VM, owned disk/address, workload/deadline service accounts,
grants/custom roles and jobs from that workspace state. Verify authoritative
resource absence and reconcile provider-triggered deletion in state. Keep GCS,
platform and evidence; do not equate VM disappearance with complete cleanup.

Acceptance: expiry remains bounded during failures, all workspace-owned resources
are absent after teardown, and bucket data is retained.

## E. Independent end-to-end acceptance

On GCP alone, launch and connect, clone an external repo, install dependencies,
read multiple small authorized GCS objects and write/download a test object.
Pass the deterministic NumPy/pandas example. No production training or
cross-provider image/output comparison is required. Exercise
denied access, disconnect and native expiry. Destroy and repeat with the same
retained bucket. Publish a clean-checkout quickstart and infrastructure evidence.

Done without AWS/Azure credentials, registry copies or homelab services. Offline
checks stay non-mutating; live IAM, publication, apply and destroy remain separate
exact authorization gates.
