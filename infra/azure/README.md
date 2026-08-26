# Azure OpenTofu roots

The Azure implementation is split into three independent state boundaries:

- `bootstrap/` creates only the dedicated local-state backend resources;
- `platform/` creates persistent storage, registry, identities and networking;
- `runner/` creates one disposable, deadline-bound Linux VM deployment.

The platform does not grant a broad results-container writer or own a shared
runtime identity. Each runner state creates one deterministic per-deployment
managed identity and its data-read, ACR-pull, exact run-spec, exact bounded-log,
results-prefix and exact local-receipt-handoff grants. This prevents concurrent
or stale deployments from unioning permissions on one principal. The
`control-input` handoff is workload evidence, not success authority. The runtime
identity has no assignment on the separate `control` container; only the
unattached publisher identity can create final control evidence and receipts
there. The publisher can read only exact local-receipt and bounded-log evidence
patterns. Account support for the version-2 Blob-path conditions remains a live
plan/policy gate.

The accepted platform interface also binds the dedicated bootstrap state account
and container. Platform and runner preconditions reject a workload/state storage
mix, while the external runner backend key remains deterministic from provider,
subscription, region and deployment ID. Apply is accepted only during the
reviewed five-minute window beginning at `started_at_utc`; the absolute deadline
must remain within the request's maximum runtime.

No root stores a storage key, SAS token, client secret or private SSH key. Local
operator authentication uses Azure CLI credentials already established outside
this repository; non-interactive execution must use a reviewed temporary
identity mechanism.

`bootstrap` intentionally retains local OpenTofu state. After its exact saved
plan is separately reviewed and authorized, its outputs provide the identifiers
used by the example Entra-authenticated backend configurations in `platform`
and `runner`. The initial state endpoint is reachable through Azure's public
service endpoint but accepts Entra authorization only: shared keys, SAS inputs
and anonymous container access are disabled. A later reviewed hardening plan may
add a private endpoint after operator connectivity is designed. Never initialize
either remote backend against placeholder values.

## Offline validation

From the repository root:

```bash
bash tests/azure/test-scaffold.sh
tofu fmt -check -recursive infra/azure
```

Provider installation and schema validation may be performed without backend
access:

```bash
for root in bootstrap platform runner; do
  tofu -chdir="infra/azure/${root}" init -backend=false
  tofu -chdir="infra/azure/${root}" validate
done
```

`init -backend=false` downloads only pinned provider packages. It does not read
or write Azure state and does not contact Azure APIs. No command in this README
authorizes `plan`, `apply`, `import`, state mutation or resource destruction.
