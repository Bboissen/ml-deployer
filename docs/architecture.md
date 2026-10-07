# Architecture

Historical batch interface. The [workspace interface 2.0.0](workspace.md)
now defines the accepted product boundary. Provider workspace migration is
pending; existing batch code, contracts and evidence remain preserved.

## System boundary

This repository creates equivalent infrastructure behavior on AWS, Google
Cloud, and Azure. It does not own model code, training parameters, data
transformation, experiment scheduling, or result analysis.

| Concern | Infrastructure repository | ML repository |
| --- | --- | --- |
| Cloud resources, state, IAM, network, deadline | Owns | Does not modify |
| OCI image | Verifies digest and runs | Builds and publishes |
| Run specification | Treats as opaque bytes | Defines and validates |
| Data/results objects | Owns storage and access policy | Owns content |
| Trial allocation | Exposes independent runners | Chooses provider and trial |
| Final receipt | Publishes through trusted control identity | Consumes |

DigitalOcean, Ray clusters, cross-cloud networking, local ML execution, and a
persistent orchestration service are out of scope.

## Deployment flow

```text
ML repository
  ├─ OCI repository + sha256 manifest digest
  └─ immutable provider-local run-spec object
                 │
                 ▼
reviewed runner request ──> saved plan ──> exact authorization
                 │
                 ▼
disposable runner + deployment identity + outbound-only address
  ├─ reads generic data and its exact run spec
  ├─ pulls the exact OCI digest
  ├─ runs the container once
  ├─ writes only its result/log prefixes and local receipt handoff
  └─ terminates at the provider deadline
                 │
                 ▼
trusted publisher, never attached to the runner
  ├─ reads bounded handoff, log, manifest, and provider lifecycle facts
  └─ conditionally creates evidence and the final completion receipt
                 │
                 ▼
runner-only destroy; platform storage, registry, and receipts remain
```

## State ownership

Each provider has three flat root modules. Provider configuration exists only
in roots; there is no shared cloud-resource module.

| Root | Ownership | Lifetime |
| --- | --- | --- |
| `bootstrap` | Remote-state storage only; bootstrap itself keeps local state | Rarely changed |
| `platform` | Generic storage, registry, trusted publisher, and provider network boundary | Persistent |
| `runner` | One VM, disk, runtime identity/grants, outbound address, and deadline resources | Disposable |

State storage is never workload storage. Runner destruction must not use or
target bootstrap/platform state.

## Provider mapping

| Capability | AWS | Google Cloud | Azure |
| --- | --- | --- | --- |
| Compute | EC2 | Compute Engine | Linux VM |
| Runtime identity | IAM role/instance profile | Service account | Managed identity |
| State backend | S3 native lockfile | GCS locking | AzureRM Blob locking |
| Workload storage | S3 | Cloud Storage | Blob Storage |
| Registry | ECR | Artifact Registry | ACR |
| Operator tool | AWS Systems Manager | OS Login/IAP when enabled | Run Command |
| Runtime deadline | EventBridge Scheduler + guest shutdown | VM max duration + Scheduler delete | Auto-shutdown + guest shutdown |

AWS Systems Manager (SSM) is AWS's provider-native remote-management service.
It lets an authorized operator inspect or open a session without exposing SSH
to the internet. GCP IAP and Azure Run Command serve the same operational role.

## Network model

There is no Tailscale control plane. It would add agents, secrets, routing, and
another service without improving the normal one-shot workflow.

- No provider creates an inbound internet rule by default.
- GCP and Azure attach outbound addresses to the disposable runner, so those
  addresses disappear with runner state; persistent Cloud NAT/NAT Gateway is
  intentionally absent.
- AWS currently keeps its accepted VPC/subnet/internet-gateway platform graph
  and gives the runner a public outbound address with a no-ingress security
  group. Changing accepted live addresses is a separate migration, not a
  documentation cleanup.
- All durable inputs, results, logs, and receipts live in provider object
  storage. The network is transport, not persistent application state.

## Storage and identity

Every provider separates state, generic data, and results/control storage.
Persistent resources are private, encrypted, recoverable, and protected from
routine destroy. The Gold dataset remains absent until a later reviewed
integration.

The deployer manages OpenTofu resources. A deployment-unique runtime identity
can read data/image/run-spec inputs and write only its own outputs. A distinct
publisher identity can create trusted control evidence and receipts but is
never exposed to the VM. Any operator/publisher federation or impersonation
binding is a provider-specific acceptance task.

## Capacity and termination

Profiles express workload capacity and map to provider SKUs in each runner
root. Live CLI quota/capacity checks decide what can launch; documentation does
not impose a separate concurrency or spending ceiling.

Every runner still has a provider-side maximum-runtime safeguard plus guest
shutdown. Subscription plans, credits, and quotas do not terminate a hung VM
at the requested deadline.
