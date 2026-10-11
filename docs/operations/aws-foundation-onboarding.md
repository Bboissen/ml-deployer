# AWS foundation onboarding (M3 + remaining M1)

The controller prepares account/project-specific bootstrap and platform inputs,
plans their separate roots in order, binds each saved plan to the task scope and
captures actual platform/guard outputs. Retained foundations require the original
successful authorization, immutable plan/config/output hashes and an exact native
state version, lineage and serial. Same names and a successful login do not permit
adoption. Uncertain bootstrap/platform applies stop for reconciliation.

The cpu-python-v1 catalog remains us-east-1 with its pinned Amazon Linux image.
Discovery paginates regional usage and offerings, observes standard On-Demand CPU
quota and current AWS pricing, then ranks supported r8i sizes by usable RAM and
CPU. Only an explicitly selected hourly ceiling constrains prices. Storage,
requests, transfer, IPv4, guard and secrets costs are separate scope items.

User and ordinary role operators have distinct inline grant resources; session
control uses the caller's AWS userid. SSO reserved roles require an owner-managed
operator role/permission set route; an STS success is insufficient. Platform trust
and deployer permissions follow the selected exact native principal.

Private GitHub onboarding requires repository administration and authorization
for the read-only deploy key and scoped Secrets Manager secret. Registration
records its intent and returned GitHub ID before secret creation. Failures require
reconciling those exact objects rather than blindly registering again. Private
keys are temporary RAM files (Linux tmpfs, macOS native RAM disk), never inputs to
OpenTofu, evidence or process arguments. The operator owns revocation/rotation.
Public repositories need no runtime credential. Existing reviewed references
remain supported by the advanced interface.

The M6 CLI composes these controller functions. Source checks use mocked AWS and
GitHub only. No new cloud mutation, key registration, native operator acceptance
or alarm-delivery acceptance was performed for this change. The generated SNS
alarm topic is encrypted and retained; subscriptions require their own selected
transport and confirmed delivery before advertising notifications.

Run `python3 -B tests/aws/run-offline.py` for bounded checks. The harness removes
exact new test payloads/provider copies in finally and retains small logs and
cleanup receipts; existing evidence and user tools are preserved.
