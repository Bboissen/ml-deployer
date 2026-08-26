# Google Cloud OpenTofu roots

This directory implements the GCP side of the accepted cross-cloud contract as
three independent state boundaries. It does not contain credentials, provider
account selection, a saved plan, state, or cloud evidence. None of these roots
has been initialized against a remote backend or applied.

## Roots

- `bootstrap/` uses local state and supports two explicit modes. `create`
  defines a new private, versioned state bucket. `adopt_managed` performs only a
  read-only control check against a named candidate and requires a reviewed
  inventory/state-lineage digest. It has no import block and cannot move or
  adopt state.
- `platform/` defines new protected data/results buckets, Artifact Registry, a
  private VPC/subnet/NAT, and a distinct keyless receipt-publisher service
  account. Persistent resources use
  `prevent_destroy`; neither bucket uses `force_destroy`. Only explicitly
  temporary or unaccepted result prefixes have a seven-day deletion rule.
- `runner/` defines one disposable Compute Engine VM, boot disk, and unique
  keyless workload service account. It has no external IP, enables OS Login
  only with the accepted platform IAP flag, executes the shared digest-pinned
  guest contract, and configures native `max_run_duration` with the `DELETE`
  action.
  The same runner state owns an absolute Cloud Scheduler DELETE job and a
  keyless custom role/service account that can delete only that exact VM.

Every runner state creates a deterministic service account unique to its
deployment and owns all of that identity's grants: generic read on the one data
bucket, pull from the exact Artifact Registry repository, read of the one
content-addressed run-spec object, and create access only to its own `results/`
and `logs/` prefixes plus the exact local-receipt handoff key. Destroying a
runner state therefore removes its grants without accumulating union-of-prefix
access on a persistent or concurrently reused identity. The receipt-publisher
identity can read only the known bootstrap-log and local-receipt handoff suffixes
and can create only below `control/evidence/` or `control/receipts/`; receipt
objects must also end in `/completion.v1.json`. It is never attached to the VM.
This configuration grants no one impersonation of that publisher. A later
read-only effective-IAM review must still prove that no inherited project or
organization binding lets the runner impersonate it before any plan can be
accepted.

The guest writes its local execution receipt only to a private, unmounted host
directory. On every bounded bootstrap path, the provider wrapper retains the
guest exit code, truncates the captured bootstrap output to at most 1 MiB, and
uses GCS generation precondition `0` to create—but never overwrite—the log at
`runs/<deployment_id>/logs/bootstrap.log` and the exact local-receipt handoff at
`runs/<deployment_id>/control-input/execution-receipt.local.json`. Evidence
publication failure after a successful guest run changes the wrapper result to
nonzero; an existing guest failure remains the terminal process result. These
handoffs are inputs, not terminal evidence: the later control publisher must
bind them to independently read Compute facts and conditionally create content-addressed
control evidence and the final receipt. A runner must not be applied until that
publisher adapter and metadata verification are reviewed.

The common contract requires a result-manifest checksum for success but does
not yet freeze a manifest object name. This scaffold does not invent one or
grant the publisher arbitrary result-object read access. Successful receipt
publication remains blocked until the ML/common boundary supplies a reviewed
canonical manifest reference and the corresponding exact read condition.

The publisher's Compute observer role contains only
`compute.instances.get` and `compute.instances.getSerialPortOutput`. Google
Cloud IAM does not expose instance labels as a condition attribute for these
permissions, so the binding uses the strongest stable resource-name boundary
available here: the selected project's reviewed regional zone namespace and
the reserved `ml-` instance-name prefix. This remains an account-bound live
review item; the publisher adapter must reject any observed instance whose
deployment metadata does not match the accepted request and platform binding.

Guest shutdown clears Compute Engine's duration-derived termination timestamp.
The absolute Scheduler job therefore remains independent of native
`max_run_duration`: it issues an OAuth-authenticated DELETE for the exact VM at
the reviewed UTC minute, using bounded retries. Cloud Scheduler cron is
recurring, so runner reconciliation must remove the job with the rest of the
runner state after terminal observation. A later invocation after deletion gets
an idempotent not-found response and cannot delete any other resource because
the custom IAM condition binds the exact instance name. Before plan acceptance,
`doctor` must prove the Cloud Scheduler API is enabled, its Google-managed
service agent has `roles/cloudscheduler.serviceAgent`, the deployer can attach
the deadline identity, and the selected Scheduler region is ready. This root
does not enable an API or repair service-agent IAM.

## Backend key binding

The GCS backend stores named workspaces as `<prefix>/<workspace>.tfstate`.
`platform/backend.gcs.example.hcl` therefore uses the provider/project/region
prefix with the required workspace `platform`. The runner example adds
`runner` to the prefix and the root refuses to plan unless
`TF_WORKSPACE=<deployment_id>`. This produces the contract key:

```text
gcp/<project_id>/<region>/runner/<deployment_id>.tfstate
```

The platform emits one closed `platform_binding` object and its SHA-256. It
binds project, region, the selected state bucket, distinct data/results buckets,
network, subnetwork, registry, publisher identity, fixed storage namespaces,
and interactive-access flag. A runner consumes that object as a whole,
recomputes its hash, rejects a mismatch, and rechecks that state, data, and
results remain three distinct buckets. The lifecycle adapter must additionally
prove that the initialized backend bucket equals the binding; OpenTofu input
variables cannot inspect backend configuration.
Both platform and runner roots expose that verified digest under the common
`platform_contract_sha256` output name; `platform_binding_sha256` remains the
provider-specific alias.

`started_at_utc` is the reviewed earliest apply time and the root derives a
fixed five-minute `latest_apply_at_utc`. It rejects plan evaluation outside that
window and rejects an absolute deadline that is not later than the window or is
later than `started_at_utc + maximum_runtime_minutes`. The lifecycle executor
must repeat the clock check immediately before applying the exact saved-plan
digest because a saved plan freezes expression values.

Backend initialization, workspace creation, import, state movement, planning,
application, and destruction are deliberately outside this scaffold. Each
requires the accepted lifecycle interface and its own review gate.

## Offline validation

Generate or refresh a root lock file only during reviewed dependency work. The
routine provider test reuses committed locks, isolates plugin working data in a
temporary directory, disables the backend, and contacts no cloud API:

```text
bash infra/gcp/tests/validate-offline.sh
```

This does not prove GCP identity, visibility, quota, effective IAM, Scheduler
API/service-agent readiness, create authority, backend locking, capacity,
boot-image suitability, or receipt publication. Those remain live Goal 04
gates.

## Historical resources

The last preserved receipt records four GCS buckets and four service accounts,
but this scaffold assigns none of them ownership. Before choosing an existing
name or importing an address, operators must refresh read-only inventory and
classify every historical resource as adopt, retain externally, or decommission.
No historical resource may be silently replaced or orphaned.
