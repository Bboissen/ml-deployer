# Tests

`make check` is the single offline entry point. It runs:

1. repository layout, Markdown links, JSON parsing and shell syntax checks;
2. workspace record validation, the toolbox probe and the deterministic example;
3. the AWS installer, guide, doctor, configuration, onboarding, ingestion, job,
   deploy, recovery, release and lifecycle suites, each in a disposable source
   snapshot with a cleanup receipt under ignored `evidence/aws/test-receipts/`;
4. backend-disabled `tofu init` and `tofu validate` for every AWS root, plus the
   mocked `tofu test` plans the lifecycle and storage suites inspect;
5. recursive OpenTofu formatting.

Nothing here contacts a cloud account. Provider downloads may use the OpenTofu
registry when the locked package is not cached.

`tests/aws/test-workspace-installer.sh NEW_EVIDENCE_DIRECTORY` additionally runs
the pinned AL2023 toolbox installer in a local container with systemctl stubbed
and no AWS credentials. It needs Docker and network access, so it is not part of
`make check`.
