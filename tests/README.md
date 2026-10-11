# Tests

`make check` is the single routine offline entry point. It runs:

1. repository layout, Markdown links, JSON parsing, shell syntax, and diff
   whitespace checks;
2. workspace request/handoff/readiness, toolbox and deterministic fixture checks;
3. the complete AWS controller, installer, doctor, ingestion, job, recovery and
   release regression suites, each in a disposable source snapshot;
4. AWS, GCP, and Azure scaffold tests, including locked
   `tofu init -backend=false` and `tofu validate` for all nine roots;
5. recursive OpenTofu formatting checks.

Every AWS automation suite records its exact deleted scratch path and verifies
cleanup. Tests never infer ownership by scanning changes to real operation
evidence. Existing tools and runtime environments are preserved.

AWS checks include single-configuration rendering, complete production handoff
validation with mocked OpenTofu user-data, timezone-aware SDK dates, scoped IAM
and lifetime behavior. `make historical-check` runs preserved batch contract,
OCI source and dummy-dispatch compatibility checks separately.

`tests/aws/test-workspace-installer.sh NEW_EVIDENCE_DIRECTORY` additionally runs
the entire pinned AL2023 installer locally, with systemctl stubbed and no AWS
credentials. It requires Docker and the manifest's local image, downloads pinned
public packages, and retains its container/logs. It is an explicit non-default
check because of those local runtime and network requirements.

Provider scaffold tests also use focused fail-closed mutations for identity,
backend, digest, result-prefix, receipt-authority, deadline, inbound-network,
and runner-only ownership invariants.

The default suite never applies infrastructure or contacts cloud APIs.
Provider downloads may use the OpenTofu registry when the locked package is not
cached. Evidence-bound AWS plan/live checks and local OCI image import are
explicit non-default Make targets.
