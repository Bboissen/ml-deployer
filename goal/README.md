# Implementation goals

This directory is the progress index, not live-state evidence. Before any cloud
mutation, verify the current repository commit, exact saved plan, external
evidence, and fresh provider CLI output.

| Goal | Status | Next gate |
| --- | --- | --- |
| [02 Common contract](02_COMMON_CONTRACT_AND_TOOLING.md) | Accepted | Change only through explicit contract review |
| [03 AWS](03_AWS.md) | Tasks A/B accepted | Complete publisher path, artifact publication, runner acceptance |
| [04 Google Cloud](04_GCP.md) | Offline implementation | Resolve existing-resource/state ownership, identities, then plan |
| [05 Azure](05_AZURE.md) | Offline implementation | Complete deployer/publisher path, then bootstrap plan |
| [06 Cross-cloud](06_CROSS_CLOUD_ACCEPTANCE.md) | Not started | Wait for all three provider runner lifecycles |

Rules:

- One provider and one state root per reviewed plan.
- Each apply, upload, IAM change, and destroy has its own exact authorization.
- Passing offline checks does not advance a live acceptance gate.
- Provider tasks may differ internally but must preserve the common contract.
- Account/deployer/publisher setup is an explicit task, never an assumed
  prerequisite.
