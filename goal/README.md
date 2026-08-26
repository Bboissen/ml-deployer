# Implementation goals

The goals are sequential. A later goal may be designed in advance but is not implemented or applied until the preceding acceptance gate is complete.

| Goal | Status | Outcome |
| --- | --- | --- |
| [00 Scope and preservation](00_SCOPE_AND_PRESERVATION.md) | Accepted | Infrastructure-only boundary and preservation rules |
| [01 Clean reset](01_CLEAN_RESET.md) | Accepted | Minimal, honest tracked baseline |
| [01B Legacy disposition and purge](01B_LEGACY_DISPOSITION_AND_PURGE.md) | Not started | Remove all quarantined legacy material from the workspace |
| [02 Common contract and tooling](02_COMMON_CONTRACT_AND_TOOLING.md) | Not started | Frozen OCI, storage, runner and command contracts |
| [03 AWS](03_AWS.md) | Not started | Accepted AWS bootstrap, platform and disposable runner |
| [04 Google Cloud](04_GCP.md) | Not started | Adopted GCP foundation and accepted disposable runner |
| [05 Azure](05_AZURE.md) | Not started | Accepted Azure bootstrap, platform and disposable runner |
| [06 Cross-cloud acceptance](06_CROSS_CLOUD_ACCEPTANCE.md) | Not started | One common run contract proven on all providers |

## Execution rules

- Each implementation task uses one branch and one pull request.
- Broad provider goals are split into bootstrap, persistent platform and disposable runner tasks.
- Every task stops for review before commit, cloud apply and merge when those are separate decisions.
- A provider goal is not complete because its code validates. It requires the acceptance evidence listed in that goal.
- No goal authorizes deletion of historical local material or live resources unless it names the exact target and disposition.
- Goal 01B must be accepted before Goal 02 or any provider implementation begins.
