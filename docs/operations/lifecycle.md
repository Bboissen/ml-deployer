# Operator lifecycle

Historical batch interface. The [workspace interface 2.0.0](../workspace.md)
now defines the accepted product boundary. Provider workspace migration is
pending; existing batch code, contracts and evidence remain preserved.

This is the shortest safe path from local validation to a destroyed runner.
Commands and examples in the repository are the authority; this guide does not
assert that a live identity, quota, backend, or resource still exists.

## 1. Validate locally

```bash
make check
```

The routine suite is offline. It may download exactly locked providers, but it
uses `tofu init -backend=false`, does not authenticate, and does not call cloud
APIs.

## 2. Authenticate and verify scope

Follow the relevant account setup guide for
[AWS](../account-setup/aws.md), [Google Cloud](../account-setup/gcp.md), or
[Azure](../account-setup/azure.md), then:

```bash
source scripts/load-cloud-env.sh PROVIDER
```

Use provider CLI `get`, `list`, `describe`, and quota commands to confirm the
active identity, account/project/subscription, region, required services,
current inventory, and requested capacity. Read visibility does not prove
create permission.

## 3. Complete provider identities

Before the first plan, identify and verify all three actors:

1. the human or CI source identity using temporary authentication;
2. the OpenTofu deployer identity and its federation/impersonation path;
3. the trusted receipt publisher and the mechanism that invokes it outside the
   runner.

The runtime identity is created in runner state. It must not be able to assume,
attach, or impersonate the publisher.

## 4. Plan one root

Initialize only the selected `bootstrap`, `platform`, or `runner` root with its
reviewed external backend configuration. Write the binary plan, JSON rendering,
input files, CLI identity output, and SHA-256 hashes to durable evidence storage
outside this repository.

Review the exact resource actions, account/region binding, IAM, backend key,
replacements/deletions, and runner deadline. A changed input, lock file,
identity, backend, source tree, or plan produces a new review artifact.

## 5. Apply only an exact authorization

An apply must name the provider scope, root, saved-plan SHA-256, and deployment
ID when applicable. Apply the reviewed binary plan without an implicit replan.
Preserve terminal output and state/version evidence. On failure, stop; do not
retry, import, edit state, or clean up automatically.

AWS's accepted platform has additional evidence-bound checks in
[AWS platform acceptance](aws-platform-acceptance.md).

## 6. Publish and run

Image publication, run-spec upload, publisher-policy changes, runner plan,
runner apply, trusted receipt publication, and destroy are separate mutations.
The OCI workflow is [documented here](oci-conformance.md).

Operator access is provider-native and normally non-network-persistent:

- AWS Systems Manager (SSM): remote session/command service using the instance
  role and agent, with no inbound SSH rule.
- GCP: OS Login through IAP only when explicitly enabled for exact principals.
- Azure: Run Command through the Azure control plane, with no inbound rule.

## 7. Observe and destroy

Observation is read-only. It reports VM state, deadline, bounded logs, local
handoff, result manifest, final receipt, and provider-authenticated publisher
metadata. VM liveness or output presence alone is not success.

Destroy from the one deployment's runner state using a separately reviewed
saved destroy plan. Verify afterward that the runner, disk, runtime identity,
grants, deadline, and runner-owned address are gone while state, data, results,
registry, control evidence, and receipts remain.
