# Scripts

Scripts in this repository must be small infrastructure lifecycle entrypoints. They must not implement training, scheduling, data transformation or result analysis.

`check-repository.sh` runs the offline repository and contract suite. `validate-runner-request.sh` validates one closed versioned request, `hash-runner-request.sh` computes its normative canonical checksum, `validate-deployment-index.sh` verifies exact runner/backend binding, `validate-command-result.sh` validates a lifecycle envelope, and `validate-completion-receipt.sh` validates the closed receipt payload without contacting a provider. A receipt payload still requires provider-authenticated publisher and object-version evidence before it can establish success.

The live lifecycle adapters described in [`../docs/operations/interface.md`](../docs/operations/interface.md) are added inside the provider goals. They share command behavior and JSON envelopes, not provider credentials or resource code.
