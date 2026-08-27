# Tests

`make check` is the single routine offline entry point. It runs:

1. repository layout, Markdown links, JSON parsing, shell syntax, and diff
   whitespace checks;
2. semantic request, receipt, index, command, result-manifest, and guest tests;
3. static OCI source and registry-tool conformance tests;
4. AWS, GCP, and Azure scaffold tests, including locked
   `tofu init -backend=false` and `tofu validate` for all nine roots;
5. recursive OpenTofu formatting checks.

Provider scaffold tests also use focused fail-closed mutations for identity,
backend, digest, result-prefix, receipt-authority, deadline, inbound-network,
and runner-only ownership invariants.

The default suite never applies infrastructure or contacts cloud APIs.
Provider downloads may use the OpenTofu registry when the locked package is not
cached. Evidence-bound AWS plan/live checks and local OCI image import are
explicit non-default Make targets.
