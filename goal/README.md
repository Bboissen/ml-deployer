# Implementation goals

Goals 00, 01, 01B and 02 are sequential. After Goal 02 is accepted, the AWS, Google Cloud and Azure provider goals become independent sibling workstreams that may proceed in parallel. Goal 06 begins only after all three provider goals are accepted.

| Goal | Status | Outcome |
| --- | --- | --- |
| [00 Scope and preservation](00_SCOPE_AND_PRESERVATION.md) | Accepted | Infrastructure-only boundary and preservation rules |
| [01 Clean reset](01_CLEAN_RESET.md) | Accepted | Minimal, honest tracked baseline |
| [01B Legacy disposition and purge](01B_LEGACY_DISPOSITION_AND_PURGE.md) | Accepted | Quarantined legacy material removed and recovery evidence archived externally |
| [02 Common contract and tooling](02_COMMON_CONTRACT_AND_TOOLING.md) | Accepted | Frozen OCI, storage, runner and command contracts |
| [03 AWS](03_AWS.md) | In progress — Tasks A and B accepted | Disposable runner acceptance pending |
| [04 Google Cloud](04_GCP.md) | In progress — account readiness verified | Historical-resource adoption, platform and runner acceptance pending |
| [05 Azure](05_AZURE.md) | In progress — account readiness verified | State bootstrap, platform and runner acceptance pending |
| [06 Cross-cloud acceptance](06_CROSS_CLOUD_ACCEPTANCE.md) | Not started | One common run contract proven on all providers |

## Execution rules

- Each implementation task uses one branch and one pull request.
- Broad provider goals are split into bootstrap, persistent platform and disposable runner tasks.
- Every task stops for review before commit, cloud apply and merge when those are separate decisions.
- A provider goal is not complete because its code validates. It requires the acceptance evidence listed in that goal.
- No goal authorizes deletion of historical local material or live resources unless it names the exact target and disposition.
- Goal 01B must be accepted before Goal 02 or any provider implementation begins.
- Goals 03, 04 and 05 branch independently from the accepted Goal 02 baseline; none may alter the frozen common contract or another provider's roots without a separate review.
- Goal 06 requires accepted evidence from all three provider workstreams.
