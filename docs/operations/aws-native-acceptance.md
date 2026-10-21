# Native acceptance

`make check` runs offline against mocked providers. Before a release, each case
below must also pass in a real AWS account. This page is the procedure for that
run; it does not authorize one.

## Scope a run

Start small: one non-sensitive local input of 8–16 MiB, at most 64 MiB
transferred, 100 MiB of outputs and 30 minutes of runtime, with an explicit
hourly price ceiling and a small repository that provides `make setup` and
`make train`. Run `./workspace project.json` on committed source, stop at the
review and keep the printed scope. It resolves the real account,
region and zone, commit, source hash and bytes, bucket and resource names,
machine size, quota, price and compute estimate. Authorize only that scope.

A first run also creates persistent resources that outlive the job: separate
encrypted, versioned state and workload buckets, a network without ingress,
IAM boundaries, expiry schedules, queue, logs, alarms and an encrypted SNS topic
with a rotating KMS key. A private repository adds a read-only deploy key and
its secret. Record an owner and retention deadline for them, and their storage,
KMS, IPv4, request and logging charges separately from the compute quote.
Quota increases, permanent IAM keys and deleting unrelated resources are out of
scope; deleting retained resources later needs its own authorization and a
verified receipt.

Each further deployment needs its own reviewed scope. The controller allows one
launch per reviewed operation; it does not cap total spending across runs.

## Cases

| Case | Offline source coverage | Required native evidence |
| --- | --- | --- |
| Linux/macOS installation and login | Four platform branches, corrupt downloads, installer faults, archive/config round trip | Clean-host runtime pins, CLI/SDK identity and supported operator grants on both OS families |
| Foundation/access | Multiple accounts/projects/roles, scope/lineage checks, partial-state recovery boundaries | Least-privilege operator, actual IAM propagation, outputs, private key ownership and alarm delivery |
| Identity Center sign-in and operator rebinding | Mocked setup review/apply, append-only profiles, chained-profile login, exact trust/denial rebinding plans and launch-evidence edges | Portal sign-in, credential renewal past one role-credential lifetime without a browser, and a retained foundation rebound from a console operator, followed by a launch |
| Local/S3/public HTTPS ingestion | Streaming, multipart aborts, source change, checksum/version checks | >1 MiB input, same-region source, immutable destination manifest, failed transfer before any launch |
| Generic projects | Two command styles; setup/job/output failures; non-root and timeout boundaries; mocked dataset staging and its rejections | Two ordinary repositories reading `DATA_DIR` and writing `OUTPUT_DIR`, with durable declared outputs without fixture-specific result hashes |
| Retained reuse | Two mocked Deploys reuse exact manifests without another upload | Second native operation rereads exact source/output versions and retains storage after compute absence |
| Controller loss/cancel | Locks, fsynced journal, uncertain launch refusal, ownership recovery | Terminal/network loss, expired login, partial apply and SIGKILL leave no duplicate VM and preserve expiry |
| Teardown | Guarded mocked retirement and exact owned absence checks | Instance, root disk and interface absence; output versions still readable; unrelated resources unchanged |

Keep native state, plans, authorizations, journals and receipts under the
installation's ignored `evidence/` root. After every test, including failures,
remove only the disposable payloads, containers, runtimes and caches it
created, by exact ID or path; retained resources and evidence are not scratch.
Publish a release only after these cases pass or the unsupported scope is
explicitly narrowed.
