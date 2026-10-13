# Goals

Launch an ML-ready AWS machine, connect, clone an independent ML repository and
work with a persistent S3 dataset, all from one guided command. This repository
owns the machine, buckets, toolbox, access and safe lifetime. The external
repository owns dependencies, data content, ML scripts and results.

| Goal | Outcome | Status |
| --- | --- | --- |
| Guided first use | `make` installs pinned tools, asks for project settings, saves the file and offers native sign-in; a read-only companion page shows progress | Implemented; offline and clean-container coverage |
| Reviewed Deploy | One immutable scope (account, zone, commit, bytes, size, price, lifetime), one confirmation bound to its hash, durable recovery | Implemented offline; [native acceptance](../docs/operations/aws-native-acceptance.md) pending |
| Bounded workspace | Non-root toolbox on EC2, S3 data/output prefixes, Session Manager terminal, provider-side expiry guard | Bounded private job accepted natively (PR24); generic acceptance pending |
| Release | Deterministic archive and standalone installer from committed source | Candidate `0.1.0-rc.1`; publication is an owner decision |

## Execution rules

- Sizing is RAM-first within the account's remaining regional quotas: among
  supported CPU machines maximize RAM, then vCPUs. Pin the selected size in the
  plan; never request quota increases, change billing or fall back silently.
  Quota is a capacity limit, not a spending cap; report costs separately.
- Keep state storage and workload storage distinct. Teardown retains datasets
  and infrastructure evidence; deleting retained resources is a separate decision.
- Use temporary native identities and a provider-side maximum lifetime that also
  covers partial deployment and failed guest startup.
- Retain the exact scope and receipts for every cloud mutation. A task
  authorization covers routine steps inside that scope; ask again only for a
  material expansion.
- Routine tests stay offline. Passing them does not establish live acceptance.
- CPU workspaces only. GPU, distributed frameworks and persistent ML services
  need separately scoped work.
