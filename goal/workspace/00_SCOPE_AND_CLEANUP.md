# Scope and cleanup

Target accepted on 7 October 2026. Implementation is pending. This goal replaces
the image-first synthetic batch demonstration as the repository's final target.

## Final product and ownership

All providers use the [RAM-first, quota-bounded default](../README.md#execution-rules).
Select and pin the largest eligible supported CPU machine for the named target;
account restrictions do not authorize quota increases or replace lifetime/cost review.

Launch one ML-ready machine on AWS, Google Cloud or Azure, connect to it, clone
an independent project, and access a persistent dataset bucket on that provider.
This repository creates the machine, toolbox, storage, identity, access and
bounded lifecycle. Its ownership ends when those facilities are ready to use.

The independent ML repository owns its code, dependency locks, data content,
transformations, training, experiment settings, checkpoints and results. It
chooses and runs its own entrypoint. Infrastructure must not parse model
parameters, schedule trials, grade results or publish ML completion receipts.
Project-specific libraries are installed from that project's requirements;
the toolbox is not a promise to preinstall every ML framework.

Each deployment uses one provider's compute, identity, network, state and object
storage: S3 on AWS, GCS on Google Cloud, Blob containers on Azure. Native GCS
and Blob interfaces are supported; an S3 compatibility gateway is not required.
No cross-cloud coordination, replication, failover, common registry mirroring,
homelab scheduler, local VM, VPN control plane or home tracking server is needed.
An operator's terminal is a management client, not a required runtime service.

## Task 1: reconcile the baseline

- Preserve the dirty working tree and audit evidence; compare main and PR18/19
  before selecting useful fixes. Do not blanket-merge the old demo architecture.
- Keep flat provider roots, version locks, native identities, storage separation,
  meaningful IAM tests, exact saved-plan review and lifecycle evidence.
- Introduce a versioned workspace interface. Preserve old requests, receipts and
  saved plans as historical evidence; do not relabel them as workspace acceptance.
- Keep the existing `runner` root name during migration unless a separately
  reviewed state/backend change is necessary. Its new purpose is workspace
  ownership, not automatic execution of one ML container.

Review gate: a concrete integration and resource-disposition plan, with exact
paths and state ownership, before implementation or pruning.

## Task 2: remove obsolete product scope

Retire the mandatory tool-complete dummy, its large fixed package matrix and
hardcoded input paths, ML-specific result/receipt validators and trusted ML
publisher workflow from the default interface. Remove Ray Tune, Spotify
planning/code, model ladders, HPO, SHAP and MLflow demonstrations from required
infrastructure acceptance. Keep a small deterministic NumPy/pandas example that
proves libraries, native bucket access and known numerical results. This bounded
test exception does not transfer production ML ownership into this repository.

Classify each script, schema, template, test, document, registry and publisher
resource as keep, replace, export or retire. Remove wrappers that only propagate
demo hashes. Retain tooling that proves state isolation, access denial, deadline
coverage and storage preservation. Update `make check` alongside its scope.

Old live resources are adopted, retained with an owner, or decommissioned through
their exact reviewed scope. Removing resource blocks or references is not a safe
cleanup method. Preserve state, plans, authorizations, receipts and archives.

## Task 3: finish local cleanup and documentation

- Export `docs/ml-project/` to a separately selected destination before removing
  it. Review `.dummy-runtime/`, old acceptance registries, BuildKit resources and
  their mounts; remove only specifically approved, owned targets.
- Keep durable local state and operational evidence under ignored `evidence/`.
  Record and verify every migration/pruning receipt. Keep layout docs tracked.
- Remove obsolete default demo commands and stale architecture claims after
  replacement acceptance. Make repository checks detect out-of-scope leftovers.
- Document the launch/connect/storage/teardown journey and provider capabilities
  plainly. Unimplemented capabilities must remain marked pending.

## Completion

The default workflow provisions storage and a usable toolbox without requiring
a training script, Ray service, preloaded dataset, trusted ML publisher or
homelab process. The small acceptance fixture uses an isolated test prefix only.
All removed live/local resources have verified disposition evidence. Each cloud
can reach its own acceptance independently. Source cleanup alone does not prove
cloud cleanup.

Code tasks use small branches/PRs and stop at review milestones. Cloud mutation,
IAM, publication, file deletion and resource cleanup retain their exact review
and authorization requirements.
