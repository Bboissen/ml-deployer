# Independent cloud ML workspace goals

Accepted target: launch an ML-ready machine, connect, clone an independent ML
repository, and work with a persistent native object-store dataset. This repo
owns the machine, bucket, toolbox, access and safe lifetime. The external repo
owns project dependencies, data content, ML scripts and results.

Shared foundation 2.0.0 is implemented and checked offline. Provider workspace
launch commands remain pending; historical image-first dummy workflows are
preserved until each reviewed migration.

## Current goals

| Goal | Outcome | Status |
| --- | --- | --- |
| [Shared foundation](workspace/05_FOUNDATION_AND_HANDOFF.md) | Versioned interface, bounded example, ownership and independent task prompts | Offline complete; review gate |
| [Scope and cleanup](workspace/00_SCOPE_AND_CLEANUP.md) | Reconcile state and remove obsolete demo/application scope | Exact inventory proposed; no cleanup executed |
| [Toolbox contract](workspace/01_TOOLBOX_CONTRACT.md) | Clone-ready workspace, native storage, bounded lifetime and a small deterministic example | Shared implementation; provider acceptance pending |
| [AWS](workspace/02_AWS.md) | EC2 toolbox, S3 and Session Manager | Planned |
| [Google Cloud](workspace/03_GCP.md) | Compute Engine toolbox, GCS and reviewed IAP/OS Login | Planned |
| [Azure](workspace/04_AZURE.md) | Linux VM toolbox, Blob and reviewed interactive access | Planned |

Each provider has its own reconciliation, storage/identity, toolbox/access,
lifetime/teardown and end-to-end acceptance tasks. They can be implemented and
accepted separately. None depends on another provider or a homelab service.

Keep a small locked NumPy/pandas example with a tiny bucket fixture and known
count/sum/mean output. Run it independently on each cloud to prove the toolbox
and storage path. Stop expanding the previous model/HPO/tracking demonstration.

## Execution rules

- Start with baseline and ownership reconciliation, then review each bounded task.
- Preserve existing working changes and review useful main/PR18/PR19 fixes before
  integration; do not import the old demo architecture wholesale.
- Keep provider code and state separate. Share only equivalent tooling/contracts
  and the small acceptance example, not runtime coordination or cloud resources.
- State storage and workload storage remain distinct. A workspace teardown retains
  datasets and infrastructure evidence; explicit resource disposition comes first.
- Use temporary/native identities, exact operators and a provider-side maximum
  lifetime that also covers partial deployment and failed guest startup.
- A saved plan, IAM change, data upload, apply, destroy or local pruning step each
  retains its own exact reviewed authorization. A goal is not an apply approval.
- Routine tests remain offline. Passing them does not establish live acceptance.
- CPU workspaces are the first target. GPU/distributed frameworks and persistent
  ML services require separately scoped compatibility and lifecycle work.

## Previous plans

The numbered Goal 02-06 files in this directory document the earlier batch/demo
stage. They are superseded as final product goals. Preserve their accepted
artifacts and existing contract behavior until reviewed migration; retire stale
planning prose during cleanup. They do not require a new three-cloud synthetic
campaign before the useful workspace can be delivered.
