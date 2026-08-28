# Runner contracts and fixtures

Goal 02 freezes these provider-neutral artifacts:

- `runner-request.schema.json`: one normalized request for one runner state;
- `completion-receipt.schema.json`: authoritative atomic cloud completion receipt;
- `local-execution-receipt.schema.json`: portable guest outcome before provider enrichment/upload;
- `result-manifest.schema.json`: canonical bounded list of workload result objects and content hashes;
- `deployment-index.schema.json`: discoverability record for isolated runner states;
- `command-result.schema.json`: frozen version-1 envelope for `doctor`, `plan`,
  `observe`, and `destroy`; newer dummy lifecycle operations use their own exact
  evidence rather than impersonating a version-1 command;
- `resource-profiles.json`: provider-neutral capacity floors and runtime bounds;
- `fixtures/`: equivalent valid AWS/GCP/Azure requests and fail-closed examples;
- `receipt-fixtures/`: terminal completion-receipt examples;
- `index-fixtures/`: bound runner-state index examples;
- `command-fixtures/`: lifecycle result-envelope examples.

The JSON Schemas are structural interoperability documents. Draft 2020-12 cannot express sibling-field equality such as an embedded deployment/checksum path or a backend key derived from four other properties. Therefore acceptance always requires both structural conformance and the corresponding dependency-free semantic validator under [`../../scripts/`](../../scripts/README.md); schema-only acceptance is forbidden. The regression suite exercises the cross-field failures through those normative validators. Receipt payload validation is itself still insufficient: provider goals must additionally verify the authenticated publisher identity, conditional creation and provider-assigned object version returned outside the immutable payload.

The normative design is [`../../docs/contract.md`](../../docs/contract.md).
