# Native acceptance scope and remaining evidence

No new cloud mutation, key registration or dataset upload is authorized by the
source implementation handoff. This is the review procedure for an eventual
bounded campaign, not permission to execute it.

Start with one non-sensitive local input of 8–16 MiB, maximum transfer 64 MiB,
maximum outputs 100 MiB, maximum runtime 30 minutes and an explicit hourly price
ceiling. Use a small external repository with declared setup/run commands. Run
`project.json deploy` without authorization on committed source and retain its
scope. This resolves the actual account/operator, region/zone, commit, source
hash and bytes, precise bucket/key/resource namespaces, current RAM/quota/price,
retained resources and compute estimate. Attach that concrete scope before
asking for native execution authorization; no historical account/ARN or fee
assumption is sufficient.

Scope includes a separate encrypted versioned state bucket and workload bucket,
no-ingress network, deployer/project boundaries, watchdog/expiry schedules,
queue/logs/alarms and encrypted SNS topic with rotating customer KMS key. A
private repository additionally needs an exact new read-only deploy key/native
secret scope or verified owned reference. These persistent resources survive
the job. Record their owner, retention/decommission deadline and extra
storage/KMS/IPv4/request/observability charges separately from the compute quote.
No paid quota increase, production Gold, permanent IAM keys or unrelated
resource deletion is in scope. A later retained-resource deletion needs its
own exact authorization and verified receipt.

Authorize only the selected operation after that review. Each additional
deployment needs a scope inside the authorized campaign's total launch/transfer
budget. The source controller defaults to one launch per reviewed operation;
it does not enforce a multi-operation campaign spending cap.

| Case | Offline source coverage | Required native evidence |
| --- | --- | --- |
| Linux/macOS installation and login | Four platform branches, corrupt downloads, installer faults, archive/config round trip | Clean-host runtime pins, CLI/SDK identity and supported operator grants on both OS families |
| Foundation/access | Multiple accounts/projects/roles, scope/lineage checks, partial-state recovery boundaries | Least-privilege operator, actual IAM propagation, outputs, private key ownership and alarm delivery |
| Local/S3/public HTTPS ingestion | Streaming, multipart aborts, source change, checksum/version checks | >1 MiB input, same-region source, immutable destination manifest, failed transfer before any launch |
| Generic projects | Two command styles; setup/job/output failures; non-root and timeout boundaries; mocked dataset staging and its rejections | Two ordinary repositories reading `DATA_DIR` and writing `OUTPUT_DIR`, with durable declared outputs without fixture-specific result hashes |
| Retained reuse | Two mocked Deploys reuse exact manifests without another upload | Second native operation rereads exact source/output versions and retains storage after compute absence |
| Controller loss/cancel | Locks, fsynced journal, uncertain launch refusal, ownership recovery | Terminal/network loss, expired login, partial apply and SIGKILL leave no duplicate VM and preserve expiry |
| Teardown | Guarded mocked retirement and exact owned absence checks | Instance, root disk and interface absence; output versions still readable; unrelated resources unchanged |

Keep native state, immutable plans, authorizations, journal, receipts and exact
object metadata under that installation's ignored evidence root. Preserve the
historical PR24 evidence. Remove only campaign-owned disposable test payloads,
containers, runtimes and caches after every test, including failures, with
verified exact IDs/paths; retained native resources/evidence are not scratch.
Publish a release only after the named native cases pass or their unsupported
scope is explicitly narrowed. Mocked CI passing is not that acceptance receipt.
