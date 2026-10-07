# AWS workspace milestone A

This milestone provides named account targets, bounded read-only preflight and
resource disposition. It consumes [workspace interface 2.0.0](../workspace.md)
from merged PR20 and PR21 (`982a236b37906518d47892ba9141338368c5336a`).
The corrected cleanup lineage is present. Historical provider roots and their
state addresses remain intact. Stop at the milestone-A review gate below.

## Account-switching quickstart

Run commands from the repository root. Requirements: Bash, Python 3.10+ and an
existing AWS CLI v2 temporary-credential profile. This task used AWS CLI 2.36.14;
OpenTofu remains pinned to 1.12.3 and the AWS provider to 6.61.0. No SDK package
is installed or prescribed to an external project by this milestone.

Copy [the sanitized example](../../infra/aws/targets.example.json) to
`evidence/aws/targets.json` and replace every invented binding with reviewed
metadata. This is an AWS-owned configuration; `.env` remains historical and is
not sourced by the new commands. Native profiles remain in their existing AWS
CLI files. The target contains no credentials, caches, signed URLs or login tokens.

```bash
umask 077
mkdir -p evidence/aws
cp infra/aws/targets.example.json evidence/aws/targets.json
# Edit the local JSON with approved profile/account/role/backend metadata.
bash scripts/aws/workspace-target.sh list
bash scripts/aws/workspace-target.sh identity aws-personal
timeout 210s bash scripts/aws/workspace-target.sh preflight aws-personal
bash scripts/aws/workspace-target.sh exec aws-personal -- aws sts get-caller-identity
```

Selection is explicit on every command. For two reviewed targets, these can run
simultaneously in separate terminals without changing a global active profile:

```bash
# Terminal 1
bash scripts/aws/workspace-target.sh identity aws-personal
# Terminal 2
bash scripts/aws/workspace-target.sh identity aws-lab
```

SDK processes use the same native credential chain. For example, in an external
project environment with an appropriate boto3/botocore version installed:

```bash
bash scripts/aws/workspace-target.sh exec aws-personal -- python -c \
  'import boto3; print(boto3.client("sts").get_caller_identity()["Account"])'
```

The launcher checks operator STS account and exact user/role before starting the
child, then sets `AWS_PROFILE`, `AWS_DEFAULT_PROFILE`, both region variables and
`AWS_SDK_LOAD_CONFIG`. Ambient AWS credentials, profiles, endpoints, OpenTofu
variable/argument overrides and metadata fallback are rejected. The error lists
conflicting variable names only; clear those variables in the invoking terminal
and rerun. Missing/expired login, missing native profiles, static keys without a
session token and competing native credential sources fail before inventory.
An explicitly named config/credentials file is supported and inspected locally;
its contents are never logged. Trusted existing `credential_process` profiles
are supported. Native web-identity/metadata credential sources are deliberately
closed in this interactive operator implementation.

The child command is trusted operator code, not a sandbox. Explicit AWS profile,
region and endpoint argument overrides are rejected for direct AWS CLI commands.
Code must use the inherited profile/region and must not install its own credentials
or override a boto3 Session. `exec` grants no mutation authorization; milestone-A
invocations remain read-only. OpenTofu execution through it is closed.

## Native login and OpenTofu context

Refresh the existing login method yourself. For an existing console-login profile,
use `aws login --profile PROFILE` and approve in the browser. For an already
configured IAM Identity Center profile, use `aws sso login --profile PROFILE`.
Do not activate Identity Center, change IAM or accept an unintended identity
replacement to solve a login failure. Login runs outside the target launcher,
because it may update the selected native profile/cache. Inspect the resulting
identity with the target command before proceeding.

[AWS console login](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
requires CLI 2.32.0+ and appropriate existing login permission. If an older SDK
cannot consume `login_session`, AWS documents an explicitly configured
`credential_process` bridge using `aws configure export-credentials --profile
SIGNIN_PROFILE --format process`. Configure that bridge yourself, then bind the
target to its native profile. Never print/export its credential JSON into logs,
configuration or chat. This tooling does not rewrite CLI configuration or create
long-lived keys.

```bash
bash scripts/aws/workspace-target.sh context aws-personal platform
bash scripts/aws/workspace-target.sh context aws-personal runner
```

Context preparation authenticates first, then records provider variables,
deployment-role intent, backend profile/account/bucket/key scope, source revision
and dirty-source hash. Platform context includes a credential-free `backend.hcl`.
Runner context records its approved prefix; an exact workspace key still needs
review. `TF_DATA_DIR` is under
`evidence/aws/TARGET/CONFIG_HASH/contexts/SOURCE_ROOT_BINDING_HASH/tofu-data/`.
Changed target bindings, roots or source select a different directory. Evidence
has separate immutable timestamped check directories; symlink reuse is rejected.
The native [S3 backend](https://opentofu.org/docs/language/settings/backends/s3/)
uses its own explicit profile and account allowlist, independent of provider
configuration. Backend configuration is not a credential store.

No init, plan, state access through OpenTofu, or apply is implemented here.
Bootstrap retains its historical local state and is not assigned a new backend.
Platform authenticates as the selected operator; the historical runner provider
additionally assumes the declared deployer role. That assumption and its effective
rights remain a separate prerequisite before any runner plan. Later implementation
must check exact role identity, default workspace, root variable precedence and
backend account, and seal each plan with source/target/account/region/backend,
state lineage/serial/version and plan SHA-256. It must never reuse another target's
initialization, plan, authorization or state, or migrate historical state implicitly.

## Read-only evidence and its limits

Preflight checks authentication, region/availability zones, the standard on-demand
EC2 vCPU quota, EC2/disks/addresses/network, reviewed schedule groups, IAM roles
and policy metadata, regional S3 bucket names and reviewed bucket protection,
exact backend objects/versions and reviewed ECR repositories/digests. Account-wide
EC2/IAM listings detect resources needing ownership classification; they do not
confer repository ownership. Global IAM and S3 names are scoped to the selected
account; compute/registry/schedules to its selected region/groups.

Each request has a 20-second subprocess bound, one retry attempt and no automatic
pagination. Collection stops issuing requests after 160 seconds, with a 180-second
collection bound; the outer `timeout 210s` is the bounded monitoring command.
Listings have a first-page limit of 100 where supported; only ten runner state or
schedule details are read. State content is version-pinned, limited to 2 MiB and
parsed in memory into lineage/serial/resource-address/selected-resource-ID metadata.
State outputs, complete attributes and raw error text are not saved. Every check
records UTC time, arguments and its query. A permission failure/timeout is unknown;
continuation tokens and limits leave coverage incomplete. Do not infer absence
outside a successful complete listing. Scope and results stay ignored under
`evidence/aws/TARGET/CONFIG_HASH/checks/TIMESTAMP-PID/`.

[STS identity requires no deployment permissions](https://docs.aws.amazon.com/cli/latest/reference/sts/get-caller-identity.html).
Authentication, readable inventory, deployment rights and native workspace
acceptance are distinct. The collector explicitly leaves the last two unverified.
The quota read is current capacity metadata, not a spending cap or a launch test.

## Milestone-A resource disposition

The final bounded collection on 7 October 2026 UTC observed all 43 requested checks;
an additional scoped backend-version read found no active platform lock. That read
is recorded in `evidence/aws/milestone-a/platform-lock-metadata-receipt.json` and
included in future preflights.
The selected operator/account matched, `us-east-1` required no opt-in, six zones
were available and the standard on-demand CPU quota was eight vCPUs. Complete
first-page responses contained zero EC2 instances, volumes, reserved addresses
and schedules in the reviewed `default` group. This does not cover other regions
or unreviewed schedule groups, or establish deployment rights.

Fresh metadata matches the retained historical Task A/B ownership. The state
bucket and both workload buckets have versioning and all four public-access blocks
enabled. The data bucket contains one 4,991-byte synthetic fixture; results contains
sixteen historical object versions, including a completion receipt and logs. Neither
bucket is empty. ECR retains three image digests. No workload objects were downloaded
or rewritten, and no historical receipt was graded as workspace acceptance.

| Exact root address or scope | Fresh evidence / proposed disposition | Ownership and state implications |
| --- | --- | --- |
| Bootstrap `aws_s3_bucket.state` and six companion protection/configuration addresses | State bucket present; keep | Existing local bootstrap state lineage `471c409c-c89b-225a-1559-6021a83fbb2c`, serial 2, seven managed instances; preserve local state and versions. No remote bootstrap migration. |
| Platform `aws_s3_bucket.workload["data"]`, `["results"]` and their twelve companion configuration addresses | Present; adopt with retained contents | Keep in existing platform state; review data/output prefixes or choose new empty buckets separately. Historical objects do not become Gold inputs. |
| Platform `aws_vpc.runner`, `aws_subnet.runner`, `aws_security_group.runner`, `aws_internet_gateway.runner`, `aws_route_table.runner`, `aws_route_table_association.runner` | IDs/relationships match fresh inventory; retain/adopt | Preserve all six addresses; future egress/access changes require a reviewed platform plan. Default VPC and its dependencies are outside these addresses. |
| Platform `aws_iam_role.deployer`, `aws_iam_role_policy.deployer`, `aws_iam_policy.runtime_boundary`, `.scheduler_boundary` | Present; retain then replace policy behavior under review | Current boundary versions are v1 with zero uses. Deployer policy is inline (`demo-disposable-runner-deployer`), not a same-name managed policy. No effective-policy or assume-role acceptance claimed. |
| Platform `aws_ecr_repository.runner` | Present with three digests; retirement candidate | Registry owner is platform; preserve images until an exact separate decommission plan/export decision. Toolbox launch will not require publication. |
| Platform `aws_iam_role.receipt_publisher`, `aws_iam_role_policy.receipt_publisher` | Present; retirement candidate | Remove only in a separate reviewed platform plan after workspace migration; preserve historical control objects. Review corresponding results-bucket policy changes at `aws_s3_bucket_policy.results`. |
| Platform state object at the configured `platform_key` | Lineage `3adef62b-4d2b-e3c0-d340-ce23223dd6df`, serial 4, 27 managed instances; keep | Exact object version/IDs are in the local disposition. No addresses removed, adopted by import or moved. |
| Runner `dummy-3166c60c828b.tfstate` | Zero managed instances, lineage `dcb3dc1c-789d-d0b6-d741-3a1d1957d9f3`, serial 2; keep | Preserve empty state, previous versions, saved plans, authorizations and receipts; no runner deletion is proposed from this state. |
| Runner `dummy-3166c60c828b-r2.tfstate` | Zero managed instances, lineage `f6ed728e-406d-b445-273c-5fc0919074df`, serial 3; keep | Same preservation; current selected-region inventory corroborates compute teardown. This does not establish workspace 2.0.0 acceptance. |
| Historical Task A backend smoke states | Local preserved lineage `cd0fd92a-03e4-0346-81f1-d05612b6f6ff`; keep | Remote smoke key is outside the approved platform/runner read scope and was not refreshed. Do not prune it or treat local historical serials as current. |
| Other IAM roles and default-network resources | Observed, ownership outside platform state; retain unclassified | No cleanup scope inferred from presence in the account. |

Full metadata and exact ARNs, bucket names, network IDs, state versions, source-file
checksums and a resource-by-resource disposition are retained at
`evidence/aws/milestone-a/resource-disposition.json`. The timestamped collection
path is recorded in `evidence/aws/milestone-a/live-preflight-final.json`.
The first collection had one extra managed-policy lookup; its failure was wrongly
categorized as missing login. The append-only correction is
`evidence/aws/milestone-a/policy-lookup-correction.json`. The corrected configuration
and final collection succeeded; original evidence remains intact.

Keep bootstrap state and the dedicated state bucket under their existing owner.
Adopt persistent workload buckets/network only after matching their existing
platform state addresses. Existing content requires retention/adoption review;
new generic storage starts empty and Gold remains absent. Registry, publisher and
obsolete receipt restrictions are retirement candidates in a separate platform
plan, preserving workload buckets, network and state. August runner absence cannot
prove October absence. Unclassified resources remain outside cleanup authorization.

Main retains batch 1.0.0. PR18 added `input_object_version` to its historical AWS
request/template; PR19 made that twelve-field request fail closed before object
conversion could discard unknown fields. Preserve both branches and their evidence.
Next AWS implementation should use closed workspace 2.0.0 inputs and retain the
useful rejection behavior, without silently relabeling immutable batch artifacts.
The old wildcard SSM parameter access and EC2-before-Scheduler dependency remain
unaccepted risks; this milestone changes no IAM/resource blocks or state addresses.

## Proposed next-milestone design and review gate

Use the existing separate bootstrap/platform/runner roots. Platform keeps private,
versioned S3 state separate from persistent workload S3 and publishes scoped
`s3://` data/output prefixes. Runner creates one CPU EC2 toolbox with encrypted
owned disk, IMDSv2, no inbound rules, non-root project directory and temporary
instance-role credentials. Use named Session Manager operators, a reviewed SSM
agent/client pair and reviewed package/Git egress. Scope workload reads/writes to
the selected data and workspace-output prefixes; deny state, unrelated datasets,
other workspaces and unrelated SSM parameters in both effective policies and
permissions boundaries. Attach runtime/SSM policies before instance creation;
test bounded IAM propagation handling instead of retrying indefinitely.

The proposed guard is AWS-owned platform infrastructure: a pinned Lambda watchdog
and enabled recurring Scheduler invocation, with bounded retries and failure
notification, installed and tested before launch. Each runner also arms a one-time
schedule invoking that watchdog with its immutable workspace lease before EC2 can
exist. The payload identifies account/region/workspace and absolute expiry, without
depending on an instance ID. The watchdog resolves EC2 instances using mandatory
atomic launch tags and terminates all matching nonterminated instances, including
pending/stopped ones. Its role may describe regional inventory but terminate only
the accepted guard-tagged workspace scope; it cannot access workload/state objects.
The workload cannot change guard tags, disable termination or modify guard resources.

The launch role must enforce exact workspace/deadline tags on `RunInstances`, a
short `aws:CurrentTime` launch window and the instance profile/boundary. This closes
late or untagged launches outside the armed lease. Guard IAM attachments and actual
readiness precede schedule creation; schedule activation/readback and persistent
watchdog readiness precede compute. A persistent watchdog survives partial runner
destroy and supplements the one-time invocation. This replaces the current schedule
dependency on a newly created instance ID. No direct EC2 launch is offered until
the complete guard path passes review and native acceptance.

If guard creation/readiness fails, launch stays closed. If EC2 creation succeeds
but bootstrap, an operator session or a later apply step fails, the already armed
provider guard covers it. A partially created profile/disk/address may keep costing
money after termination: record all surviving IDs and prepare an exact runner-only
cleanup plan. Keep the guard while compute exists; never delete its state or disable
it to hide drift. Guest shutdown is supplementary; termination plus owned-volume/
address reconciliation, rather than guest timeout or budget alerts, closes billing
for the disposable resources. Storage retains its own continuing costs.

This is a design inference from AWS primitives, not an accepted hard-runtime claim.
[RunInstances supports atomic creation tags](https://aws.amazon.com/blogs/aws/new-tag-ec2-instances-ebs-volumes-on-creation/)
and [EC2 IAM supports tag conditions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ExamplePolicies_EC2.html).
[Scheduler has 60-second precision](https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html)
and [bounded retry/DLQ settings](https://docs.aws.amazon.com/scheduler/latest/UserGuide/managing-schedule.html).
Invocation/visibility/termination latency and service failure can exceed nominal
expiry. Review must define and test an early trigger, safety margin, maximum
observed termination delay, lease window and failure policy; AWS outages cannot
be presented as a guaranteed zero-overshoot financial cap. An untested watchdog
or operator cleanup procedure does not satisfy the hard-deadline readiness check.

Remaining decisions: exact adoption versus new empty workload buckets/prefixes,
named session operators, allowed instance SKU/disk/capacity, subnet egress, immutable
AMI ID/architecture, toolbox bootstrap hash, CLI/SDK/SSM/tool versions, and guard
margin/retry/notification settings. Foundation's CPU profile requests Python 3.13,
Git, uv, compiler and make; image/tool pins must be reviewed together. Do not use
an unpinned "latest" image or invent acceptance facts to fill 2.0.0 readiness.

The integration owner should register any later shared CLI/test UX or schema
changes. No shared interface/ownership files or other providers change here.

## When testing is possible

1. **This milestone:** target switching and negative behavior are testable offline
   now with `bash tests/aws/test-workspace-target.sh`; authenticated read-only
   inventory is available after native login. Two-target independence uses fakes
   unless two real, reviewed target profiles exist.
2. **Next implementation milestones:** test workspace/bootstrap, policy boundaries,
   lifetime ordering and partial failure offline, then prepare reviewed native saved
   plans once adoption, image, access, guard and effective-role prerequisites exist.
3. **After exact cloud authorization:** launch one bounded CPU workspace, connect
   through Session Manager, clone an external repository at a revision, set up its
   environment, then perform separately authorized S3 read/write/retrieval of the
   locked NumPy/pandas acceptance example. Verify isolation and deadline; perform
   authorized teardown preserving storage. Any follow-up launch needs its own scope.

Review milestone A before proceeding. Design review authorizes no deployment.
No apply/destroy/import/state move, IAM/billing change, upload or image publication
is included. Saved-plan application always needs authorization for that exact plan.
