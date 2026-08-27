# Scripts

Scripts in this repository must be small infrastructure lifecycle entrypoints. They must not implement training, scheduling, data transformation or result analysis.

`check-repository.sh` checks static repository structure, documents, JSON and
shell syntax. The Makefile composes it with contract, conformance, provider
scaffold, and format tests under `make check`.

`validate-runner-request.sh` validates one closed versioned request,
`hash-runner-request.sh` computes its normative checksum,
`validate-deployment-index.sh` verifies runner/backend binding,
`validate-command-result.sh` validates a lifecycle envelope, and
`validate-completion-receipt.sh` validates the receipt payload without
contacting a provider. A valid payload still needs provider-authenticated
publisher and object-version evidence.

`load-cloud-env.sh` reads one ignored canonical `.env` and derives the variable
names required by the selected provider CLI, SDK and OpenTofu roots. Source it
with `aws`, `gcp` or `azure` so the exports propagate into the current shell.
Executing it, including through `make cloud-env CLOUD=<provider>`, validates the
same binding in a subprocess without changing the caller's environment.

The executable lifecycle and current entry points are summarized in
[`../docs/operations/lifecycle.md`](../docs/operations/lifecycle.md). Provider
CLIs and provider-specific scripts remain separate. `dummy/dispatch.sh` is only
a common fail-closed gate and one-provider router: later provider work supplies
`dummy/providers/PROVIDER.sh`. It never contains provider commands or an
implicit plan/apply sequence, and a missing adapter is a hard failure.
