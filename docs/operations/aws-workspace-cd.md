# AWS C/D source delivery and later native test packet

The C/D source design was explicitly approved. The implementation is ready for
source review; **native milestone E has not run**. No cloud resources were created,
changed or deleted by this task. The global default maximizes RAM within observed
remaining account quotas and compatible CPU/image/zone capacity; each provider
must obtain its own account evidence. The accepted AWS default is pinned, with no
automatic quota increase, billing change or smaller-machine fallback.

## Lambda account restriction found before final delivery

A subsequent read-only AWS CLI check found account Lambda concurrency **5**, all
unreserved. The approved design used reservation **2**, which cannot fit AWS
reservation rules in this account. After reviewing the watchdog purpose, the user
approved continuing with the existing shared pool, without a reservation or quota
increase. Platform planning/apply and launch admission check that at least five
unreserved executions remain available as an account limit. This does not reserve
idle execution capacity: other Lambda functions can consume the pool. Heartbeat
and throttle alarms close new launches, while running compute has residual delay
risk. See
[AWS reserved-concurrency rules](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html).

## Accepted first workspace

| Binding | Value |
| --- | --- |
| Target / profile | `aws-personal` / `sposhfi-admin` |
| Account / region / zone | `000000000000` / `us-east-1` / `us-east-1a` |
| Project / workspace | `demo` / `demo-dev-01` |
| Operator | `arn:aws:iam::000000000000:user/sposhfi-admin` |
| Runner deployer | `arn:aws:iam::000000000000:role/demo-tofu-deployer` |
| Default machine | `r8i.2xlarge`, 8 vCPUs, 64 GiB RAM |
| Usable request | 8 CPUs, 60000 MiB RAM, 25 GiB filesystem |
| Disposable root disk | 30 GiB encrypted gp3, delete on termination |
| AMI | `ami-03c3da4cfa8e8943a`, Amazon AL2023 `2023.12.20260930.0`, x86_64/ENA |
| Network | Existing `subnet-00000000000000000`, `sg-00000000000000000`; no ingress |
| Workload bucket | New empty auto assignment `ml-demo-8aeb909b8cf3edd3` |
| Data / output | `projects/demo/data/`, `projects/demo/workspaces/demo-dev-01/output/` |
| Runner state key | `aws/000000000000/us-east-1/runner/demo-dev-01.tfstate` |

The CLI quota read found standard on-demand quota 8 vCPUs with no active usage;
X, High Memory and GPU quotas were zero. A slightly larger legacy M2 machine was
incompatible with the reviewed ENA-enabled image. Quota and zone offering do not
prove live capacity or deployment rights; launch preparation refreshes them.
The observed Linux EC2 price was $0.55568/hour, plus $0.005/hour for an ephemeral
public IPv4 address: $0.56068/hour before EBS, storage, requests, guard, transfer
and tax. Confirm prices again at E. The 60-minute lease starts at the earliest
permitted launch and triggers termination five minutes early. Remaining platform,
state, storage versions, logs, queue, alarms and guard can continue to cost money.

Provisioning happens before cloning. Set `ML_PROJECT_NAME=demo` and pass it to
storage preparation. The repository clone directory may use `Demo`; it does not
rename an existing bucket or workspace. Names stay explicit and stable across
clones and restarts.

## Source composition and safety

`infra/aws/platform/workspace-guard.tf` adds protected persistent resources to the
existing platform: an immutable numeric Lambda version with bundled locked SDK,
one-minute Scheduler fallback, scoped invocation/termination roles, encrypted
failure queue, logs and heartbeat/error/throttle/queue alarms sent to an existing
reviewed SNS topic. The Python 3.13 runtime patch remains AWS managed; the code
and bundled SDK are immutable, not the managed runtime patch. Updating the platform guard is refused while covered compute
remains. Historical buckets, ECR, network, publisher and addresses remain owned
by their existing state. Nothing is decommissioned or moved by this source task.

`infra/aws/runner/workspace` is the independent-workspace configuration profile
of the disposable AWS runner, using the existing runner backend namespace and a
fresh workspace key. It preserves B's identity/profile resource addresses and
policy template without repointing a historical runner state. It has three phases:

1. `prepare` creates scoped identity/profile, non-root Session document, named
   operator grant, a deadline armed before the earliest launch, and a bounded
   launch role. It creates no EC2 instance.
2. `launch` refreshes exact IAM/profile/document, schedules, immutable code and
   environment, complete sweep heartbeat and healthy alarms. Schedule timezone,
   start/end restrictions and completion behavior must match; alarm thresholds,
   metrics and destinations must match the reviewed platform plan. Six attempts share a
   90-second bound. Evidence older than 120 seconds closes launch. The source plan
   may create only the prepared EC2 instance and its disposable root volume.
3. `retire` revokes launch and terminates owned compute while retaining deadline
   and identity. A subsequent `cleanup` destroy plan requires the successful
   retirement receipt and native absence of the recorded instance, root volumes
   and interface before deleting disposable IAM/grants/document/deadline.

The normal deployer loses historical `RunInstances` authority when the guard is
enabled. The separate launch role binds absolute lease times, atomic ownership,
workspace and expiry tags, image/network/state key/profile. Its platform boundary
requires the reviewed SKU, ownership, IMDSv2, hop limit and encrypted storage.
Workload identity cannot mutate tags, guard, IAM or protection settings. Restart
does not extend the lease. Stopped and pending instances remain covered. New work
after expiry requires a newly reviewed lease, preparation and launch plan.

One-time Scheduler retries three times with 300-second event age; Lambda async
delivery retries twice with 300-second age and sends exhausted events to the
failure queue. A recurring scan catches missed deadlines and delayed visibility.
Malformed owned leases terminate conservatively; foreign ownership is skipped.
Each termination rechecks exact tags. Duplicate/late events do not extend a lease
or terminate a newer lease. Incomplete scans and failed termination produce no
successful heartbeat. Service outages and EC2 termination latency can exceed the
margin: this is provider-side protection, not proof of zero overshoot or a cash cap.
Partial apply/destroy consumes its authorization; retain all guard/state/evidence
and reconcile inventory before reviewing a new recovery plan. Do not replay it.

Bootstrap is a bounded systemd service with a root-owned completion record. It
stops the agent while installing, verifies the fixed AL2023 release and RPM
versions, hashes uv/AWS CLI installers, installs the hash-locked SDK, and creates
`workspace` with no sudo and `/workspaces/demo-dev-01`. The agent starts after
toolbox completion. Agent/service failure does not create a ready handoff.
Python 3.13.15, Git 2.50.1, uv 0.12.23, gcc 11.5.0, make 4.3, AWS CLI 2.36.14,
boto3/botocore 1.43.109 and SSM agent 3.3.5226.0 are pinned. The operator needs
AWS CLI 2.36.14 and Session Manager plugin 1.2.835.0; the plugin was absent at
design collection and must be installed and verified before E.

Only the existing named operator is granted the reviewed terminal document.
Run As uses `workspace`; a conflicting `SSMSessionRunAs` IAM tag closes connection.
Additional operators require separately reviewed grants and would share this OS
user's files. The existing administrator's broader AWS rights are not reduced by
this workspace grant. Run As has no fallback to the default user when its named
account is missing. See the [AWS Run As behavior](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-run-as.html).

## Local preparation and exact-plan execution

Run commands from a clean checkout of the delivered branch. Keep every artifact
under ignored `evidence/`; do not reuse or overwrite earlier directories. Install
the SDK lock in an operator Python 3.13 environment and set `WORKSPACE_PYTHON` to
its executable for native lifecycle commands. Keep credentials in the accepted
temporary native profile. A's override checks remain enforced; its generic
OpenTofu `exec` is still closed. The new named lifecycle verbs are the reviewed
workspace extension. Raw direct OpenTofu mutation bypasses this protocol.

These first two commands are local preparation; build downloads verified packages
but does not publish them or call a cloud account API:

```bash
export ML_PROJECT_NAME=demo
bash scripts/aws/workspace-storage.sh prepare aws-personal \
  --ml-project-name "$ML_PROJECT_NAME" --workspace-name dev-01 --storage-mode auto
bash scripts/aws/workspace-lifecycle.sh build evidence/aws/E/artifacts-01
```

Record the returned storage directory. Supply an existing reviewed same-account
SNS topic and the complete historical platform variables in
`evidence/aws/E/platform-current.json`; preserve every existing ML project entry.
`packet` generates a closed 2.0.0 request, additive platform variables and a runner
skeleton. It intentionally omits the unobserved guard and future lease:

```bash
bash scripts/aws/workspace-lifecycle.sh packet aws-personal \
  --storage-directory "$STORAGE_DIRECTORY" \
  --artifacts evidence/aws/E/artifacts-01/artifacts.json \
  --platform-config evidence/aws/E/platform-current.json \
  --alarm-topic "$REVIEWED_SNS_TOPIC_ARN" --output evidence/aws/E/packet-01
bash scripts/aws/workspace-lifecycle.sh plan aws-personal platform \
  evidence/aws/E/packet-01/platform.tfvars.json evidence/aws/E/platform-plan-01
```

Review `review.json`, `plan.json`, the exact scope and displayed review SHA256.
For **each** later authorized saved plan, explicitly record approval and apply it:

```bash
bash scripts/aws/workspace-lifecycle.sh authorize "$PLAN_DIRECTORY" \
  --review-sha256 "$EXACT_REVIEW_SHA256" --approval "$EXPLICIT_USER_APPROVAL"
bash scripts/aws/workspace-lifecycle.sh apply "$PLAN_DIRECTORY"
```

Those commands are not authorized by this document. The manifest binds source,
configuration, target/account/region, CLI/SDK/operator/deployer/backend identities,
backend key, state version/lineage/serial/hash, locks/OpenTofu version, artifact
hashes, dependency receipts, guard/IAM observation and immutable plan SHA256.
Any drift closes apply. Authorization is single use, including failed applies.
Never replan inside apply or autoapprove a new plan. Platform mutation/deletion is
restricted; launch may not replace existing compute or edit prepared IAM.

After the separately authorized platform apply, capture its guard output and
create a future absolute lease. Choose enough lead time for preparation/review:

```bash
bash scripts/aws/workspace-lifecycle.sh outputs aws-personal \
  evidence/aws/E/platform-plan-01 --output evidence/aws/E/guard-01.json
bash scripts/aws/workspace-lifecycle.sh lease evidence/aws/E/packet-01/request.json \
  "$REVIEWED_FUTURE_UTC_START" evidence/aws/E/lease-01.json
```

Locally merge those `guard` and `lease` objects into the runner skeleton, save
`prepare.tfvars.json`, and review it. Plan preparation with the platform dependency.
After its exact apply, copy it to `launch.tfvars.json` with `phase="launch"`:

```bash
bash scripts/aws/workspace-lifecycle.sh plan aws-personal prepare \
  evidence/aws/E/prepare.tfvars.json evidence/aws/E/prepare-plan-01 \
  --dependency evidence/aws/E/platform-plan-01
bash scripts/aws/workspace-lifecycle.sh plan aws-personal launch \
  evidence/aws/E/launch.tfvars.json evidence/aws/E/launch-plan-01 \
  --dependency evidence/aws/E/prepare-plan-01
```

Launch plan/review/apply must fit the five-minute launch window and 120-second
observation freshness. If review takes longer, preserve the artifact and prepare
a new exactly reviewed lease/plan. Never relax the checks to reuse a stale plan.

## Connection, cloning and observed records

After exact launch apply, use the recorded instance ID. The same command creates
a fresh session for reconnection; it does not restart compute or extend expiry:

```bash
bash scripts/aws/workspace-lifecycle.sh connect aws-personal \
  evidence/aws/E/launch.tfvars.json --instance "$INSTANCE_ID"
```

The wrapper binds account/operator/instance/network/profile/tags/lease and checks
the server agent, client/plugin, run-as document and guard before Session Manager.
Inside the session, verify `id`, `pwd`, and `sudo -n true` is denied, then clone:

```bash
bash /opt/workspace/scripts/aws/clone-project.sh \
  "$EXTERNAL_HTTPS_REPOSITORY" "$REVIEWED_FULL_COMMIT" Demo
cd Demo
# Follow Demo's dependency instructions using this .venv.
```

Private repository authentication is operator controlled, using a short-lived
Git credential helper or interactive login in that session. Do not put credentials
in URLs, cloud-init, tfvars, state, plans, logs or handoffs. This repository installs
no Demo dependencies or production training/data transformations.

Use `aws s3api` with explicit bucket, key and `--version-id`, or the toolbox
`/opt/workspace/sdk/bin/python` and `boto3.Session(region_name="us-east-1")`.
The SDK and CLI obtain temporary instance credentials automatically; no access
keys or profiles are needed in the guest. Project environments remain separate
and install their own dependencies under their external repository's instructions.

`handoff` requires a successful exact launch receipt and current native binding.
It emits a 2.0.0 handoff without claiming readiness. Run
`workspace-guest-observe.sh --help` inside the session for the bounded, read-only
fixture/version/checksum, toolbox, identity and denied-namespace probes. Capture
its JSON directly as the named operator's native observation and retain the exact
Session ID/banner/transcript. `collect` refreshes provider facts, matches the active
session owner/document/target and agent, verifies guest evidence, and invokes the
unchanged common validator before declaring readiness. Offline fixtures cannot
substitute for these API calls.

```bash
bash scripts/aws/workspace-lifecycle.sh handoff aws-personal \
  evidence/aws/E/launch-plan-01 --instance "$INSTANCE_ID" --output evidence/aws/E/handoff-01.json
bash scripts/aws/workspace-lifecycle.sh collect aws-personal \
  evidence/aws/E/launch-plan-01 --handoff evidence/aws/E/handoff-01.json \
  --guest evidence/aws/E/guest-observation-01.json --output evidence/aws/E/readiness-01.json
```

## Milestone-E review prerequisites and candidate tests

Before any native mutations, review this PR and supply the Demo repository URL,
full commit and isolated install command; the SNS alarm destination/subscription;
current complete platform variables and target login; pinned operator client/plugin;
and native SDK/provider/backend/role/state observations. Check Lambda concurrency,
Scheduler, SSM and IAM service quotas/rights, network routes/egress, object-store
assignment protections, immutable image availability and current costs. Missing
rights, unknown backend history, unhealthy alarms or heartbeat close launch.
No native saved plan hashes or genuine ready records exist yet.

Review platform, prepare and launch plans independently, then separately authorize
the exact shared fixture/version transfers and own-output writes. Pin
`shared/workspace/example/fixture.csv` SHA256 and returned S3 VersionId; retrieve
that exact version in the guest. Install the locked NumPy/pandas acceptance
environment separately. The expected result is count **4**, sum **10**, mean
**2.5**. Write one bounded result under this workspace's output prefix using a new
key/conditional create, retain its VersionId, and download that exact version.
Record multi-object CLI/SDK access, state/unrelated/other-workspace/data-write
denials and denied IAM/tag/guard/protection mutations. All such mutations/probes
need their own exact reviewed test scope; native failure must not become mock pass.

Test non-root connect/disconnect/reconnect, failed bootstrap, interrupted apply,
missed one-time event with recurring fallback, pending/stopped/expired instances,
duplicate and late events, lost operators and termination latency. Deliberately
disabling a deadline or testing denied mutations needs explicit authorization;
never disable the persistent fallback under live compute. Measure actual expiry
and absence before calling the guard accepted.

For normal teardown, save the same runner configuration with `phase="retire"` and
plan `retire` with `--dependency` on its launch receipt. After exact authorization
and successful retirement, plan `cleanup` with the retirement dependency and the
same retire configuration. Review and authorize that saved destroy plan separately.
Unknown or residual volumes/interfaces require a separate owned-orphan review;
no implicit cleanup occurs. Stop preserves disks; termination releases the ephemeral
IPv4 and delete-on-termination root disk; cleanup removes disposable controls.
Platform guard, workload/state buckets, stored versions and evidence survive.
Re-launch a second independently reviewed workspace against that retained project
bucket and verify the exact previous object versions are still accessible.

## Offline checks

`make check` includes the C/D mocked root/behavior/IAM cases alongside A's override
regressions and B's 14 mocked plans/65 IAM cases. `make historical-check` validates
the preserved batch interfaces. Routine tests use mocked providers and backend-
disabled initialization; they create no infrastructure. A mocked apply is used
only to exercise apply-time timestamp rejection. Logs and generated fixtures remain
under unique ignored `evidence/aws/tests/cd/` runs, with bounded command timeouts.
