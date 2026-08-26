# Deployment lifecycle

No provider stack is runnable during the clean-reset milestone. This document defines the lifecycle that later provider goals must implement.

## 1. Preflight

The provider command must fail closed unless it can verify:

- authenticated account, project or subscription identity;
- intended region;
- required APIs/resource providers;
- requested CPU and family quota;
- remote-state access and locking;
- generic data and results storage existence;
- OCI reference pinned by digest;
- valid maximum runtime;
- no secret value in input files.

## 2. Plan

Planning produces a saved plan and a machine-readable summary. The summary must separate:

- persistent platform changes;
- disposable runner changes;
- IAM changes;
- billable resources;
- destruction or replacement.

A plan that touches persistent storage, state resources, an unexpected provider, or more runners than requested fails policy validation.

## 3. Review and authorization

An apply requires explicit authorization for the exact saved-plan digest. Editing configuration, refreshing the plan or changing provider credentials invalidates that authorization.

## 4. Apply

Apply consumes the reviewed plan. It must not run an implicit new plan and must not use `-auto-approve` against an unreviewed configuration.

## 5. Observe

Observation is provider-native and read-only. It reports:

- runner lifecycle state;
- provider-side deadline;
- boot/container status;
- result receipt presence;
- current resource identifiers;
- a bounded log tail.

It does not restart, retry or replace a runner.

## 6. Destroy disposable compute

Destroy uses the runner state only and proves that persistent state, data and results storage are outside the destruction plan.

Adoption, persistent-platform destruction and historical-resource decommission are separate workflows.
