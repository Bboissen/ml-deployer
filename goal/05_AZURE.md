# Goal 05: Azure

Historical batch/demo plan. The current product target is the
[workspace milestone](README.md). Existing interfaces and immutable evidence
remain preserved until a separately reviewed provider migration.

Status: **Offline implementation complete; live acceptance pending**.

## Task A: subscription, deployer, publisher, and state

- Refresh tenant/subscription, region policy, providers, quotas, resources,
  identities, addresses, and role assignments with Azure CLI.
- Verify the source/deployer identity can create the exact bootstrap resources
  and later role assignments without a client secret.
- Define how the unattached publisher managed identity is invoked outside the
  runner and how its Blob conditions are verified.
- Prepare, review, apply, and accept the dedicated Entra-authenticated state
  backend as separate gates.

## Task B: persistent platform

- Plan generic data/results/control containers, ACR, private Blob endpoint,
  no-ingress network, writer role, and publisher identity.
- Confirm the platform contains no NAT Gateway, runner VM, disk, runtime
  identity, or runner public address.
- Prove the subscription accepts the intended conditional Blob assignments.

## Task C: disposable runner

- Mirror the exact OCI manifest and upload byte-identical immutable run spec.
- Plan one VM with a deployment-specific managed identity, runner-owned
  outbound address, auto-shutdown, and guest deadline fallback.
- Apply once, observe through Azure APIs/Run Command, invoke the publisher,
  validate the trusted receipt, and destroy runner state.
- Prove VM, disk, NIC, address, runtime identity, grants, schedule, and runner
  resource group are gone while persistent storage/registry/evidence remain.

Every cloud mutation requires its own exact review and authorization.
