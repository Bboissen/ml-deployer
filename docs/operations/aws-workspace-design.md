# AWS independent workspace design and milestone history

Preserved design record. Use the [current AWS workflow](aws-workspace.md) for
the single project configuration and deployed-foundation happy path.

This milestone provides named account targets, bounded read-only preflight and
resource disposition. It consumes [workspace interface 2.0.0](../workspace.md)
from merged PR20 and PR21 (`982a236b37906518d47892ba9141338368c5336a`).
The corrected cleanup lineage is present. Historical provider roots and their
state addresses remain intact. PR22's CLI abbreviation fix was independently
verified and merged at `fee07909e6b2686c4ecd9abb0fdb05f75e0e5c7a` before B.
B adds offline project storage selection and scoped identity source. Deployment
and native access acceptance remain closed. B was reviewed and merged in PR23.
C/D source adds the toolbox, terminal and pre-launch lifetime guard; see the
[C/D runbook and later native test packet](aws-workspace-cd.md). Native milestone E
has not run. GCP/Azure implementation is outside this task.

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

The child command is trusted operator code, not a sandbox. Direct AWS CLI commands
reject profile, region, endpoint, signing and JSON/YAML input overrides, including
native option abbreviations and applicable separated or `=` value forms.
Code must use the inherited profile/region and must not install its own credentials
or override a boto3 Session. `exec` grants no mutation authorization; milestone-A
invocations remain read-only. OpenTofu execution through it is closed.

## Project storage selection (milestone B)

Supply the external ML project's canonical name and an explicit workspace suffix.
Project names are 3–32 lowercase letters/digits/internal hyphens; the derived
workspace ID is at most 48 characters. Spelling is not normalized silently.
`ml_project_name` is separate from AWS account, infrastructure `project_name` and
`resource_prefix`; historical ownership names stay intact. This invented example
derives `fraud-detection-dev-01`:

```bash
bash scripts/aws/workspace-storage.sh prepare aws-personal \
  --ml-project-name fraud-detection --workspace-name dev-01 --storage-mode auto
```

`prepare` validates the local named target without credentials or account APIs.
It writes a new immutable directory below
`evidence/aws/TARGET/storage/PROJECT/TIMESTAMP-PID/`, containing
`storage-preparation.json`, `platform-project-entry.json` and `request-storage.json`.
The record describes intended creation/reference and sets observation, compute
and deployment authorization false. It never fabricates machine handoff/readiness.
It records Git revision and AWS source/lock/common-validator hashes, which are
metadata rather than native backend/plan authorization. The preparation helper
currently supports the commercial AWS partition.

The persistent platform input is a **complete retained project map**:

```hcl
ml_projects = {
  fraud-detection = {
    ml_project_name = "fraud-detection"
    storage_mode    = "auto"
  }
}
```

Merge the prepared entry into the existing `ml_projects` map. It is deliberately
not a replacement tfvars file: OpenTofu replaces maps across var files, so supplying
only a new project would remove old entries. Retain assignments until a reviewed
migration. The map defaults to empty; historical platform inputs are still required.

| Mode | Assignment | Later authorized platform deployment |
| --- | --- | --- |
| `auto` | None | Plan one new empty project bucket; subsequent deployments keep its name/address in the same state. |
| `auto` / `existing` | Exact inspected assignment | Reuse that bucket under its declared owner/address. `existing` fails when unassigned. |
| `create` | None or the same project-managed address | Initially create, then retain the same bucket; external/historical adoption fails. |

Names are `ml-<project>-<first 16 hex characters of SHA256(account/region/project)>`.
A global-name collision fails deployment; it never triggers alternate naming or
adoption. Each project uses one workload bucket with data prefix
`projects/PROJECT/data/` and output prefix
`projects/PROJECT/workspaces/WORKSPACE_ID/output/`. State uses the dedicated bucket
and exact reviewed runner key. Resolve these URIs before interface 2.0.0 validation
and hashing; no shared fields were added.

New storage is private, BucketOwnerEnforced, versioned, AES256 encrypted and TLS-only,
with `force_destroy=false` and `prevent_destroy`. Lifecycle only aborts incomplete
multipart uploads after seven days; it expires no objects/versions. Gold remains
absent and no object uploads or ML execution accompany bucket creation.

For assigned storage, review a local JSON description containing exactly
`bucket_name`, `ownership`, `resource_address`, `state_key`. External references use
`ownership: "external"` and empty address/key. Platform assignments use
`ownership: "platform-managed"`, the existing platform key and an exact address:
`aws_s3_bucket.project["PROJECT"]`, `aws_s3_bucket.workload["data"]` or
`aws_s3_bucket.workload["results"]`. Retained addresses must match their configured
bucket. Historical contents/addresses are preserved and never described as new
empty storage. Cross-account/region reuse and ambiguous shared project buckets fail.

Include the exact reviewed bucket in the target inventory, then inspect that scope:

```bash
timeout 240s bash scripts/aws/workspace-storage.sh inspect aws-personal \
  --ml-project-name fraud-detection --assignment evidence/aws/assigned-project.json
```

Inspection performs five bounded metadata reads with expected bucket owner through
the corrected target launcher and its operator STS checks. It requires matching
region, enabled versioning, all four public-access blocks, BucketOwnerEnforced and
AES256 encryption. KMS-encrypted assignments require a separate scoped key design
and are rejected. Permission errors, missing storage, unsupported protection and
timeouts fail; none triggers creation. No existing policies/contents are changed.
Review existing lifecycle/retention and resource policies before native deployment.

The returned `assignment-inspection.json` binds target configuration, ML project,
account/region, metadata, observation time and hash. Reuse it in preparation:

```bash
bash scripts/aws/workspace-storage.sh prepare aws-personal \
  --ml-project-name fraud-detection --workspace-name dev-01 --storage-mode existing \
  --assignment evidence/aws/TARGET/storage/PROJECT/INSPECTION/assignment-inspection.json
```

Preparation checks hash, target binding and a 24-hour freshness window. The entry
carries protection facts and inspection hash. The pinned provider lacks native
versioning/public-access-block data sources; OpenTofu checks those reviewed facts
locally. An assigned-bucket data read also checks current existence/region during
a later accepted native plan; missing/denied storage fails rather than being
recreated from an old receipt. This receipt is point-in-time metadata, not a signature, deployment
authorization or proof of effective workload access. Refresh/read back protections
during later plan/apply review and bind the original receipt, source/target hashes
and exact platform lineage/version. External buckets are referenced without import,
state transfer or policy replacement. Removing/renaming managed assignments or
switching them to external references fails ordinary plans through `prevent_destroy`.
Never remove protected resource blocks to bypass that guard.

Copy the resolved storage into a complete workspace 2.0.0 request, then prepare
identity inputs using the locked foundation Python environment:

```bash
WORKSPACE_PYTHON=.tools/workspace-venv/bin/python \
  bash scripts/aws/workspace-storage.sh prepare aws-personal \
  --ml-project-name fraud-detection --workspace-name dev-01 \
  --request evidence/aws/fraud-detection-dev-01/request.json
# Include the same --assignment receipt when reusing assigned storage.
```

The unchanged common validator rejects unknown fields, overlap, state reuse and
mismatched scopes. Preparation writes the canonical request hash and
`workspace-identity-inputs.json`. It installs no ML dependencies. Use
`make workspace-test-setup` only if the locked validator environment is absent.

## Workspace identity and ordering (milestone B)

Platform owns a project boundary and minimal Session Manager managed policy. Runner
source optionally prepares a workspace role, storage policy, management attachment
and instance profile at additive `workspace` addresses. Only EC2 may assume the
workload role; its future profile supplies temporary credentials. Stable names
include the infrastructure prefix, workspace component and a scope hash. Operator
and deployer remain separate; B assumes no roles and changes no live IAM.

The workload envelope permits:

- Reading current/exact-version dataset objects under its project data prefix.
- Reading/writing current own-output objects and retrieving exact versions.
- Listing objects/versions only with a permitted data/own-output prefix.
- Scoped multipart `PutObject`, `AbortMultipartUpload`, `ListMultipartUploadParts`
  and workload bucket location reads.

It denies insecure S3 transport, object/version deletion, bucket-wide multipart listing, tagging/ACL
mutation, state/unrelated resources, IAM/guard/EC2 administration, role assumption
and arbitrary SSM/Parameter Store access. Effective policy uses the exact output
prefix; the project boundary uses the immutable role's `workspace_id` principal tag.
The workload cannot change IAM tags. Explicit denials also constrain hypothetical
additional policies/direct session resource grants. Offline tests are not proof
of live access, which also depends on resource policies, SCPs and endpoints.
See [AWS boundary evaluation](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html).

Prepared workspace and retained batch roles replace `AmazonSSMManagedInstanceCore`
with a custom policy allowing only `ssm:UpdateInstanceInformation` and four
`ssmmessages` create/open channel actions on `*`, plus explicit Parameter Store
read denial. The historical runtime boundary is narrowed at its original address.
This follows [AWS's minimal Session Manager agent policy](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-create-iam-instance-profile.html).
Operator StartSession, logging, session KMS, patching and document execution are
separate scopes. C must pin/test a supported agent, connectivity and preferences;
see [AWS message APIs](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-setting-up-messageAPIs.html).

Both profiles explicitly depend on the required inline policy and management
attachment. Existing compute consumes its original profile. Future workspace
compute must consume the prepared profile; B does not connect it to the old dummy
instance. Runner still contains unaccepted batch compute and historical required
inputs: it is not an IAM-only deployment command. C/D own reviewed composition.

Dependencies do not prove propagation. Future launch must read back role, boundary,
attachments and profile, then use bounded IAM visibility retries within the launch
lease (proposed ceiling 90 seconds/six attempts). Identity/permission failures stop;
only transient visibility errors may retry. Stop on expiry and preserve evidence.
Never widen permissions or extend the armed lease. Exact timing/native readiness
still requires C/D review.

## Native S3 guidance for later authorized acceptance

Inside an accepted workspace, AWS CLI/boto3 use the native instance role and reviewed
region. The external ML repository owns boto3/dependencies. Read an exact reviewed
version using `aws s3api get-object --bucket BUCKET --key projects/PROJECT/data/OBJECT
--version-id EXACT_VERSION --expected-bucket-owner ACCOUNT LOCAL_FILE`. Use
`list-objects-v2` / `list-object-versions` with an allowed prefix. Current and
exact-version output retrieval uses the same native APIs.

After separate upload authorization, `put-object` or boto3 `put_object` may write
only the own-output prefix. Preserve returned `VersionId`, bucket/key, account/region,
local byte size and SHA-256 in ignored evidence. Later retrieval specifies that
version, then verifies downloaded bytes/native metadata. Reject absent/`null` version
IDs for acceptance. ETag is not generally the local SHA-256.

```python
import boto3
client = boto3.client("s3", region_name="REVIEWED_REGION")
response = client.get_object(
    Bucket="REVIEWED_BUCKET", Key="REVIEWED_PROJECT_OR_OWN_OUTPUT_KEY",
    VersionId="REVIEWED_EXACT_VERSION", ExpectedBucketOwner="REVIEWED_ACCOUNT",
)
# The ML repository owns Body streaming and data processing.
```

These examples explain future use; they authorize no transfers. No native
version/negative-access acceptance is claimed. See [S3 policy action mapping](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html).

## Offline B verification and review boundary

```bash
timeout 420s bash tests/aws/test-workspace-storage.sh
make check
```

Set `WORKSPACE_PYTHON` to the existing locked environment. The AWS scaffold includes
preparation tests, mocked native plans, rendered policy fixtures and dependency
checks. Initialization uses `-backend=false -lockfile=readonly`; AWS resources/data
sources are mocked. Logs/results stay under `evidence/aws/tests/storage/`. The outer
timeout is the bounded monitoring command; no continuous polling is used. Test
plans cannot authorize deployment.

B retains historical addresses, lineages, state versions, objects and evidence.
Frozen historical Task B validators cannot approve this workspace configuration.
Shared schema and GCP/Azure implementations remain unchanged. Source rollback before
deployment is a Git revert; after an authorized apply, keep new protected blocks/
assignments and review an exact migration plan rather than drop ownership.

Stop for B review. Native OpenTofu execution through A contexts, deployment-role
assumption, transfers and live permissions remain unaccepted/unverified. Future
compute requires accepted toolbox/access **and** the pre-compute lifetime guard.
The EC2-before-Scheduler gap remains; B makes no safe-launch claim.

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
Milestone A's live wildcard SSM permissions and EC2-before-Scheduler dependency
were unaccepted risks. B narrows SSM source without applying it; the lifetime gap
remains. No state addresses or live IAM policies changed.

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

Remaining deployment decisions: real ML project/workspace names and any exact
storage assignment, named session operators, allowed instance SKU/disk/capacity,
subnet egress, immutable
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

Review milestone B before proceeding to C/D. Source review authorizes no deployment.
No apply/destroy/import/state move, IAM/billing change, upload or image publication
is included. Saved-plan application always needs authorization for that exact plan.

## C/D milestone 1: concrete source-design review

**Source design approved:** “Approve this source design and finish C+D.” This packet is source design, not compute
implementation, deployment authorization or native acceptance. Task branch:
`feat/aws-workspace-toolbox-lifetime`; exact base/head before implementation:
`50731dc21c594add1b5a23ac2a57c546f46b9cf3`. PR20–23 and PR22's direct-CLI
abbreviation fix are present. Worktree:
`/home/user/docker/Ray_terraform-aws-toolbox-lifetime`. The original dirty checkout
and other worktrees are preserved. Design evidence is local and ignored at
`evidence/aws/milestone-cd/design-01/`; no state was initialized or moved.

### Target, project and persistent ownership

Reuse `aws-personal`: account `000000000000`, region `us-east-1`, native profile
`sposhfi-admin`, operator `arn:aws:iam::000000000000:user/sposhfi-admin` and runner
preparation/teardown deployer `arn:aws:iam::000000000000:role/demo-tofu-deployer`.
The operator identity was freshly observed. Deployer assumption, SDK/provider/backend
authentication and effective deployment rights remain unverified.

The user selected **Demo**. Propose canonical `ml_project_name=demo`, workspace
suffix `dev-01`, ID `demo-dev-01`, `storage_mode=auto`, and no external assignment.
This would plan new empty platform-owned bucket `ml-demo-8aeb909b8cf3edd3` at
`aws_s3_bucket.project["demo"]`; existence/global availability is unverified.
The full retained `ml_projects` map must be supplied, preserving other assignments.

| Binding | Proposed exact value |
| --- | --- |
| Data | `s3://ml-demo-8aeb909b8cf3edd3/projects/demo/data/` |
| Own output | `s3://ml-demo-8aeb909b8cf3edd3/projects/demo/workspaces/demo-dev-01/output/` |
| State bucket | `demo-tofu-state-000000000000-us-east-1` |
| Platform key | `aws/000000000000/us-east-1/platform/platform.tfstate` |
| New runner key | `aws/000000000000/us-east-1/runner/demo-dev-01.tfstate` |

Preserve bootstrap/platform lineages and every historical runner key. Keep existing
data/results buckets, registry, publisher and their addresses/objects; their later
decommission remains separately reviewed. No Gold data is present or transferred.
Project storage protection and B's identity envelope remain unchanged.

Provisioning precedes cloning, so a clone-directory basename can suggest a project
name but cannot silently choose persistent ownership. Use the existing explicit
input, optionally supplied by an operator environment variable:

```bash
ML_PROJECT_NAME=demo
bash scripts/aws/workspace-storage.sh prepare aws-personal \
  --ml-project-name "$ML_PROJECT_NAME" --workspace-name dev-01 --storage-mode auto
```

No inferred name from this infrastructure repository, mandatory external repository
input or shared schema extension is proposed. Later namespace changes need migration
review rather than a renamed bucket or abandoned assignment.

### Image, toolbox and verification

Propose Amazon Linux 2023 default x86_64 HVM EBS image in **us-east-1**:
`ami-03c3da4cfa8e8943a`, name
`al2023-ami-2023.12.20260930.0-kernel-6.1-x86_64`, Amazon owner `137112412989`.
Scoped `DescribeImages` observed it available, created 2026-09-29, with deprecation
2026-12-28. Resolve no `latest` parameter during deployment; reread this exact ID,
owner, architecture and availability before planning. Refresh the reviewed pin if
it becomes unavailable/deprecated. See [release provenance](https://docs.aws.amazon.com/linux/al2023/release-notes/relnotes-2023.12.20260930.html).

Fix DNF to release `2023.12.20260930`, keeping Amazon's system Python separate.
The versioned repository primary metadata was fetched and its advertised SHA-256
verified; selected RPM checksums are preserved locally. Proposed direct tool pins:

| Component | Pin and installation boundary |
| --- | --- |
| Python / headers | `python3.13` and `python3.13-devel` `3.13.15-1.amzn2023.0.1` |
| venv / pip | Python 3.13 venv; `python3.13-pip` `24.2-259.amzn2023.0.8` |
| Git / git-core | `2.50.1-1.amzn2023.0.1` |
| Compiler | `gcc` `11.5.0-5.amzn2023.0.5` |
| Make | `4.3-5.amzn2023.0.2` |
| SSM agent | Amazon repository RPM `3.3.5226.0-1.amzn2023` |
| uv | `0.12.23`, x86_64 GNU release archive, SHA-256 `9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6` |
| AWS CLI | `2.36.14`, version-specific x86_64 ZIP; dedicated toolbox install |
| boto3 / botocore | Both `1.43.109`, isolated root-owned toolbox venv |
| SDK dependencies | jmespath `1.1.0`, python-dateutil `2.9.0.post0`, s3transfer `0.19.2`, six `1.17.0`, urllib3 `2.8.0`; hash-resolved lock in design evidence |
| Operator Session Manager plugin | `1.2.835.0`; currently absent on this workstation |

Amazon Linux supports [version-locked repositories](https://docs.aws.amazon.com/linux/al2023/ug/managing-repos-os-updates.html)
and [parallel Python versions](https://docs.aws.amazon.com/linux/al2023/ug/python.html).
Use exact RPM versions and signatures, archive SHA-256, and hash-required wheel
installation. AWS CLI archive hash must be recorded after verifying its signature
against the [documented AWS signing fingerprint](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
`FB5DB77FD5C118B80511ADA8A6310ACC4672475C`. Pin/hash the operator plugin artifact
before E; [AWS lists its release and supported minimum](https://docs.aws.amazon.com/systems-manager/latest/userguide/plugin-version-history.html).
No installer or bootstrap artifact hash is invented at this design gate.

Bootstrap is a bounded systemd oneshot with a 10-minute ceiling and root-owned
success/failure record, not a workload command. Stop the preinstalled SSM service
before package changes; enable its reviewed version only after creating `workspace`
without sudo access and `/workspaces/demo-dev-01` writable by that user.
Remove default `ssm-user` sudo grants and verify they do not reappear. Maintain
root ownership of toolbox binaries, manifest and bootstrap records. Bootstrap
failure, missing tools, wrong versions or interrupted execution cannot mark ready.
Do not clone/install external project code as root or publish an image.

The bootstrap bundles the unchanged common probe. Collect tool versions, venv
creation, writable directory, non-root UID, OS/architecture and observed usable
capacity. Check native SSM online state/agent version and actual session identity
separately. Interface 2.0.0 request/handoff/readiness hashes use the common validator;
handoff needs actual instance/profile/launch/deadline evidence. Local fixtures are
explicitly offline. All nine readiness checks require their own observed evidence;
no local toolbox result attests storage, access denial or guard operation.

### Capacity, egress and terminal

The user selected a RAM-first default bounded by this account's existing quota.
Fresh AWS CLI reads observed 8 standard on-demand vCPUs with no active regional
instances, and zero X/High Memory/GPU quotas. Select `r8i.2xlarge`: 8 vCPUs,
65536 MiB (64 GiB) RAM, offered in `us-east-1a`, compatible with the pinned AMI.
Among compatible eligible sizes RAM is maximized, then CPU count; use the current
R8i family as the reviewed tie choice. X-family candidates with more RAM cannot
use the standard quota. The older `m2.4xlarge` reports 70041 MiB, but its ENA
support is `unsupported` while the selected AMI has ENA enabled, so it is excluded.
Zone offering is not a reservation or proof of actual launch capacity/permissions.

The global goals now carry that selection policy for all providers, explicitly
requested by the user; GCP/Azure still require their own account/quota observations.
Quota and usage evidence is recorded at `evidence/aws/milestone-cd/sizing-02/` and
must be refreshed before native planning. No quota increase, billing change,
secret export or actual launch was performed. Account quota is not a cost cap.

Propose one on-demand `r8i.2xlarge`, one encrypted gp3
root volume of 30 GiB with `delete_on_termination=true`, baseline IOPS/throughput,
IMDSv2 required with hop limit 1, disabled metadata tags, no SSH key and no inbound
security rules. Request minima account for OS-reserved RAM and disk overhead;
readiness reports usable capacity, not the SKU's nominal totals. Standard quota
was observed at 8 vCPUs; actual availability and launch rights remain unverified.

Retain platform-owned VPC `vpc-00000000000000000`, subnet
`subnet-00000000000000000` in `us-east-1a`, SG `sg-00000000000000000`, and the
existing associated route table/IGW. Fresh metadata observed no inbound rules,
outbound access and the subnet's active internet-gateway route. Propose an
**ephemeral public IPv4** on this instance for outbound Git HTTPS, Amazon packages,
PyPI and SSM; it supplies no inbound permission. No Elastic IP, NAT gateway or
paid interface endpoint is proposed. Git HTTPS is the initial supported path;
private Git authentication is operator-controlled after connection. Never pass
tokens in user data, URLs, recorded commands, plans or logs.

The scoped AWS price-list read returned Linux `r8i.2xlarge` at **$0.55568/hour**.
[Public IPv4 is $0.005/hour](https://aws.amazon.com/vpc/pricing/), so EC2 plus that
address is $0.56068/hour before EBS, transfer, object storage, guard services and
taxes. EBS continues while stopped; obtain a regional EBS quote before native
authorization. Persistent watchdog, Scheduler, DLQ, alarms and logs have continuing
costs even without a workspace. NAT/endpoints would add fixed hourly and data
charges and do not supply general Git/PyPI egress by themselves. Review a private
network alternative if the proposed public address is unacceptable.

Recommend the one existing operator for first acceptance. Additional named users
are useful for teammates; each needs reviewed IAM access. A shared Linux user
shares files/processes, not individual OS isolation. Existing AWS administrative
rights are not reduced by a scoped grant or non-root guest session.

Use a runner-owned custom `Standard_Stream` Session document, Run As enabled,
default `workspace`, no command parameters or account-wide preference changes.
Validate that the principal has no conflicting `SSMSessionRunAs` tag; the current
user-tag read found none. IAM/session tags take precedence over document defaults
([Run As rules](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-run-as.html)).
Terminal grants restrict StartSession to this workspace's exact ownership tags
and the exact custom document, requiring document access checks. Resume/end/data
channels are limited to the named user's own sessions. Do not grant SendCommand,
other documents, port forwarding or root-session access as part of this flow.
Effective inherited privileges and actual non-root behavior remain E checks.

The future `connect` command must validate target STS identity, handoff hashes,
fresh exact-instance/profile/tags/deadline facts, SSM online status, document hash,
run-as policy and client versions, then invoke StartSession without saving its
token-bearing response. It emits concrete instance/document argv only after those
observations. Reconnect starts a new session on that same instance; supported
ResumeSession also validates the recorded session target/owner. No invented
instance ID or runnable real-machine handoff is included here.

After connection, clone an operator-reviewed external HTTPS repository, fetch and
detach at its full commit, verify `git rev-parse HEAD`, then create a writable
project-local Python environment. The external repository owns its lock/install
command and Python/dependency choices. Toolbox boto3 remains in its own environment;
projects choose their SDK themselves. Use native instance-role credentials and
the exact S3 prefixes/version IDs described above; no static credentials or home
server dependency. Repository URL/revision remain E packet inputs.

### Guard architecture and service ordering

Implement the B watchdog proposal, with a fixed ownership guard ID derived from
account/region/infrastructure scope. Platform owns protected Lambda function and
immutable published code version, invocation role, enabled `rate(1 minute)`
Scheduler schedule, log group, encrypted SQS failure queue and CloudWatch alarms.
Bundle the hash-locked SDK in the deterministic function ZIP; use Python 3.13's
AWS-managed runtime with its security updates. Code/version/SDK are pinned;
the AWS-managed runtime patch is explicitly not an immutable image claim.
The function does not run in the VPC or access workload/state S3.

Runner owns its immutable lease record, one-time Scheduler deadline, launch role,
workload role/profile, terminal document/grant and instance. Lease fields bind
account, region, workspace, request hash, unique lease ID, earliest/latest launch
and absolute expiry. Mandatory instance/volume creation tags include `ManagedBy`,
`Project`, `Root`, `GuardId`, `WorkspaceId`, `LeaseId` and UTC `ExpiresAt`.
Tags are applied atomically in RunInstances; exact values and required presence
must be enforced in IAM, not only by an HCL precondition.

Use three stages with inspected immutable plans and recorded task authorization.
Once the user authorizes the bounded native setup/test, routine stages continue
without another confirmation. A material scope expansion still requires review.

1. **Platform preparation:** install guard/policies/recurrence/visibility resources
   alongside B storage/boundaries; retain every historical address. Guard source
   success and mocked tests do not establish native readiness.
2. **Runner preparation:** create workload policies/profile, terminal access, lease,
   enabled one-time deadline and its invocation permissions; then create the
   dedicated lease-bound launch role. No EC2 exists in this plan. Policies precede
   profiles; invocation-role policies precede schedule activation. Bounded readback
   (at most six attempts/90 seconds) verifies IAM visibility. Retry only transient
   visibility errors; stop on permission failure or lease expiry.
3. **Runner launch:** configure the root provider to assume the already prepared
   launch role, check the exact role identity and state binding, then plan only
   the reviewed EC2/owned root-volume creation. The launch role gets state-lock
   access, exact profile PassRole to EC2, and narrowly
   conditioned RunInstances/CreateTags-at-creation. It has no IAM/schedule write
   permissions. Preparation and teardown use the reviewed normal deployer.

Launch planning uses `-refresh=false` because the launch identity only creates
compute. Independent native checks still verify the guard, four alarms, prepared
IAM/profile/document, network, image and capacity before planning; fresh guard/IAM
checks and the unchanged state version are required again before saved apply.

For an interrupted preparation or a source fix, use the normal `plan` command
with `--recover-from PREVIOUS_PLAN_DIRECTORY`. The previous immutable plan,
consumed authorization, target, root, configuration and current versioned state
must prove ownership. `prepare` can renew only the lease, complete missing owned
controls, or replace its tainted terminal document. `fresh-platform` recovery
permits only its two owned inline policy updates or a refreshed no-op checkpoint.
Both refuse covered live compute and foreign resources. Preserve the failed
plan and receipts; apply only the newly inspected, single-use saved plan.

After a failed launch has expired, `cleanup --recover-from FAILED_LAUNCH_PLAN`
can remove its remaining preparation controls. It verifies the consumed launch
plan, exact workspace/lease, state ownership and native compute/disk/interface
absence; it does not manufacture a successful launch receipt. The external
guard terminates stopped instances too, so EC2 leaves guest-shutdown behavior at
its default instead of issuing a forbidden post-launch attribute modification.
Bootstrap output goes to the journal and EC2 console for failure diagnosis even
when Session Manager stays disabled during installation.

Successful historical receipts and unchanged artifact content may survive a
committed source upgrade along the same Git ancestry. Every pending apply stays
bound to its exact current source, configuration, artifact hashes and state
version. No previous saved plan is replayed.

The launch role's policy fixes the AMI, subnet, SG, SKU, required metadata/encryption
and ownership/lease/deadline tags, plus `aws:CurrentTime` within a **five-minute
launch window**. It cannot extend its policy/lease, edit tags, change instance
protection, restart compute or alter guard controls. Workload B policies deny
those operations too. Revoke the old deployer's broad RunInstances grants in the
reviewed platform source policy; adding a narrower Allow does not narrow an
existing Allow. Historical dummy launch commands must fail closed rather than
offer the old EC2-before-Scheduler path. Preserve their records and state addresses.
The trusted account administrator still has external privileges; this design
does not prevent an administrator deliberately bypassing the controlled workflow.

Before a launch plan and immediately before its exact authorized apply, require
matching function version/code hash, enabled recurrence and deadline readback,
invocation-role policy hashes, non-alarmed guard status, and a successful full
recurring sweep heartbeat no more than **120 seconds** old. A heartbeat includes
guard version/scope and scan completion, not just an invocation count. Missing,
stale, partial or mismatched observation closes launch. Bind observations to the
plan and refresh through read-only checks without changing that saved artifact.
No active/mutation-capable Lambda invocation is authorized by this source task.

Propose a **60-minute** first acceptance lease, measured from earliest permitted
launch, with termination triggered **five minutes before absolute expiry**. Both
the one-time schedule and recurring sweep use that early-trigger threshold;
therefore usable session time can be shorter than the nominal maximum. Scheduler
flexible windows are off, with 300-second event age and three delivery retries.
Lambda asynchronous event age is 300 seconds with two function retries; function
timeout 30 seconds and SDK bounded timeouts/retries. The initially reviewed
reservation of two executions was amended with user approval after observing the
restricted account limit of five. Use the existing shared unreserved pool, with no
quota increase; admission checks require an unreserved limit of at least five.
Other Lambda demand may delay cleanup, so this does not guarantee execution
capacity or zero overshoot.
These are bounded attempts, not guaranteed delivery times. AWS documents
[minute-level Scheduler precision](https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html)
and [asynchronous Lambda retries/duplicates](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async-error-handling.html).

Watchdog scans all pages of regional guard-owned inventory within its execution
bound and records incomplete scans as failures. It validates tags and lease time
bounds, describes again before termination, and terminates each exact matching
pending/running/stopping/stopped instance separately. No match is not accepted as
permanent absence: recurring sweeps continue. Exact owned instances with malformed
expiry/lease tags fail to termination; foreign guard/account/project/root tags are
never adopted. Its IAM termination permission also requires the exact static
ownership tags; it cannot alter protection/tags or read storage. Terminated and
shutting-down instances are handled idempotently. Duplicate/late events cannot
extend a lease or affect a later workspace lease; recurrence covers missed events,
failed bootstrap, disconnected operators and eventual EC2 visibility.

Propose failure visibility through the persistent DLQ, Errors/Throttles/incomplete
sweep alarms and missing-heartbeat alarm. A reviewed existing SNS alarm destination
is a native-launch prerequisite; none has been supplied or subscribed here.
Retain the queue/log/guard state under platform ownership. Retry recovery never
extends a lease or widens IAM. **No finite AWS-outage latency bound or zero-overshoot
financial cap is claimed.** Native E must measure invocation/visibility/termination
delay; exceeding the five-minute safety margin fails acceptance and closes later
launches pending review. Guest shutdown is supplementary.

Stop/restart cannot renew expiry. Initially support reconnect and separately
authorized stop/teardown; do not expose a restart/relaunch shortcut. A stopped
instance remains guard-covered until termination. Replacement/relaunch needs a new
lease, refreshed guard observations and separately authorized saved plan; retained
storage is reused. Unexpected replacement in an ordinary launch plan is rejected.

### Plans, partial failure and storage-preserving teardown

Extend the AWS-owned launcher deliberately; keep milestone A's generic OpenTofu
exec rejection and abbreviation/ambient-override regressions. Commands select an
exact named target, root, default OpenTofu workspace, phase and state key; never
use a context from another source/root/target. Pin OpenTofu/provider/lock files
unchanged. Separate provider, SDK, backend and assumed-role identity checks;
operator STS alone proves none of the other bindings.

Before native planning, bind exact retained backend version/lineage/serial and
verify no unexpected resource ownership changes. Seal immutable source/config
snapshots, request/assignment/guard/lease hashes, identities, account/region,
backend bucket/key/workspace, state version/lineage/serial, plan SHA-256 and allowed
mutation scope. Artifacts and TF_DATA_DIR stay under this repository's ignored
evidence root. Phase/identity changes select fresh initialization contexts but
retain the same reviewed runner key/lineage. Recheck source/config/state and live
guard/lease facts before apply; reject stale/conflicting bindings or an expired
window. Apply only the exact reviewed plan after explicit authorization, never
auto-replan. Present no fabricated hashes or native plan at this gate.

Dependencies retain deadlines/launch permissions until compute removal. Normal
teardown first revokes launch eligibility and terminates the exact owned instance,
then verifies its disk/address deletion before removing disposable deadline,
terminal grants/document and workload/launch roles/profiles. A second reviewed
cleanup plan is required where an initial partial destroy leaves dependencies.
On failure, retain guard/lease/state/evidence and inventory surviving resource IDs;
no orphan sweep or historical cleanup is implied. Never remove the platform guard
while any covered compute may remain; protected guard deletion requires a separate
complete inventory/disposition review. Buckets, versions and state survive runner
teardown. Stop leaves disk costs; termination deletes only explicitly owned
delete-on-termination disks and releases the proposed ephemeral address; residual
volumes/addresses and persistent storage/guard costs require honest reconciliation.
See [EC2 lifecycle and retained-resource billing](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html).

### Offline validation and subsequent milestone E

The approved implementation changes AWS-owned paths only. Keep shared 2.0.0,
integration-owned executable files and other provider implementations unchanged.
The user-authorized global sizing prose is proposed for integration-owner review;
any further shared executable change requires its own proposal. Preserve historical source
validation where compatible, explicitly testing its launch closure.

Add meaningful mocked plans/behavior tests for guard-before-compute graphs, all
IAM statements, exact AMI/profile/storage/session binding, tool/bootstrap failure,
missing/stale/mismatched guard evidence, lease/tag/window rejection, duplicates,
delayed visibility, expired/stopped instances, interrupted preparation/launch/
destroy, replacement refusal and retention. Reuse B's 14 mocked plans/65 IAM cases
and A's direct-CLI override regressions; run make check, historical compatibility,
locked root validation and diff checks. Logs/results remain ignored, commands
bounded with a monitoring script. These checks do not establish native guard or
machine readiness.

Final source gate will provide one AWS PR, clean tracked worktree, exact head/base,
tests and accounted untracked files, and leave the PR unmerged. E's later packet
must identify the Demo external repository/full commit and isolated install
command, a reviewed alarm destination, platform/runner effective identity/backend
checks, exact saved plans/scopes, launch timing/costs, and separately authorized
fixture transfers. Pin the shared CSV/version/hash, expect count 4/sum 10/mean 2.5,
retrieve the exact output version, test state/unrelated/other-workspace denials,
non-root connect/reconnect, missed deadline/fallback/expiry, failed bootstrap and
storage-preserving teardown/reuse. Native plan hashes and ready records are only
produced when their actual prerequisites and observations exist.

The user approved this source design. C/D implementation and the concrete later
native test packet are described in the [C/D runbook](aws-workspace-cd.md).
Source delivery stops at PR review. No native plan hash, machine readiness,
cloud mutation, or milestone-E acceptance is asserted here.
