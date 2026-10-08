# Fresh AWS workspace foundation

Use this path after an explicitly reviewed decommission. It keeps existing IAM
and alert destinations intact. Historical AWS roots, local states, saved plans
and evidence remain archived; never apply them to the fresh backend.

The persistent root is `infra/aws/platform/workspace/`. It owns only project S3
storage, outbound networking, a dedicated workspace deployer, project/launch
boundaries, minimal Session Manager channels and the accepted watchdog. It does
not create ECR, paired batch buckets, a receipt publisher or historical boundaries.
The dedicated deployer cannot launch EC2 directly or restart instances; launch
uses the prepared role with the reviewed window, tags, image, network and guard.
The existing admin remains the recovery identity. Its privileges are not reduced.

The independent bootstrap root is `infra/aws/bootstrap/workspace/`, with an
explicit local backend. Its seven state-storage resources use a new bucket named
`<prefix>-tofu-state-<account>-<region>-ws-v1`. Its local state, backend metadata,
plans and receipts stay under `evidence/`. The persistent platform and disposable
workspace use distinct canonical keys in that new bucket, with new lineages.

These AWS-only commands extend `workspace-lifecycle.sh`. Milestone A's generic
OpenTofu dispatcher remains closed. Every apply uses one reviewed saved plan and
a single-use authorization; source approval never authorizes cloud creation.
Unexpected existing names, access denials, state/identity drift and partial applies
stop the workflow. Preserve their evidence and review a new recovery scope.

1. Build the pinned toolbox/watchdog artifacts with `build DIRECTORY` from the
   delivered clean source. Use the locked Python/SDK operator environment.
2. Run `foundation-packet TARGET --artifacts ARTIFACTS_JSON --alarm-topic TOPIC_ARN
   --output PACKET_DIRECTORY`. It produces the request, bootstrap and minimal
   platform configurations and proposed target metadata. It enables no compute.
   The first accepted workspace is Demo/dev-01, with new empty auto S3 storage.
3. Run `bootstrap-plan TARGET PACKET/bootstrap.tfvars.json PLAN_DIRECTORY`.
   Review its `review.json`, seven creates, local state path and saved-plan hashes.
   Only then record exact approval with `authorize` and use `apply PLAN_DIRECTORY`.
   Initialization binds the local state path; no state migration is performed.
4. Run `plan TARGET fresh-platform PACKET/platform.tfvars.json PLATFORM_PLAN
   --dependency BOOTSTRAP_PLAN`. The successful bootstrap receipt is mandatory.
   Existing role/policy, bucket, function, queue, schedule, log-group or alarm names
   block creation. This stage permits only exact new resource addresses, with no
   updates, replacements, deletions, IAM adoption, alert changes or EC2 instances.
   Review and authorize that separate saved plan before applying it.
5. Run `activate-target PLATFORM_PLAN --output ACTIVATION_DIRECTORY` only after
   its successful apply. It compares the actual deployer's trust, inline policy
   and attachments to the immutable plan and verifies a genuine temporary STS
   assumption. It archives the old registry before atomically publishing the new
   backend/deployer metadata locally. It does not change credentials or IAM.
6. Choose the future lease with `lease PACKET/request.json START_UTC LEASE_JSON`.
   Run `runner-packet PLATFORM_PLAN --packet PACKET --lease LEASE_JSON --output
   RUNNER_CONFIG`. Network IDs and guard outputs come from the applied platform;
   deleted historical IDs cannot enter the new packet. Plan `prepare` with the
   platform dependency. Existing terminal grants/documents/deadlines block this
   create-only stage. Review and apply its exact plan, then use the established
   guarded `launch`, terminal, observation, `retire` and `cleanup` stages.

Backend initialization before saved apply rebinds the exact reviewed configuration.
Root locks and source/config/artifact/state/dependency hashes are checked. Target
activation does not declare the guest ready. Genuine guard, IAM, deadline and
heartbeat observations still precede launch. Empty/partial CloudWatch pages are
collected within the existing bounded pagination protocol.

The RAM-first default remains r8i.2xlarge, 8 vCPUs/64 GiB within the observed
restricted quota, with a 30 GiB encrypted disposable root disk, no inbound rules,
and a 60-minute lease triggering termination five minutes early. Recheck current
quota, AMI provenance, availability and price before native launch. Shared Lambda
capacity and AWS outages can delay termination; protection is not a cash cap.

Offline acceptance covers both new roots with mocked providers and rejects old
IAM changes, missing bootstrap protections, name collisions and unknown absence.
`make check` includes these cases. Native acceptance remains a later exact review:
cloud fixture transfers, the external repository/revision, Session Manager access,
negative storage permissions, expiry and storage-preserving teardown must be
authorized explicitly. Gold and production ML remain outside this repository.
