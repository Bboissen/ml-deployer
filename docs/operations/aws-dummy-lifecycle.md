# AWS tool-complete dummy lifecycle

This runbook covers only the AWS adapter for Goal 03 Task C and Goal 06. The
state bootstrap and persistent platform remain separate accepted roots. A
passing check, a saved plan, or authorization for one artifact never
authorizes the next mutation.

## Frozen common base

The adapter branch starts at accepted commit
`a64586739539e797f829aeeb80b2f974823962d8` with these immutable bytes:

| Artifact | SHA-256 |
| --- | --- |
| `requirements.lock` | `b0da526c30d04795e051671353ccafc85c99fb4ecaf8ee7b88e934659715aec3` |
| `image-source-manifest.json` | `ab8c33165d3bbe17531bec2aeaeb93aef6f452c58edbded3fd9edb6a14ce5834` |
| `run-spec.example.json` | `0bb4de28f818b1c8155a038367d2bd364f190ce43c98a55f5ffaba42881082f5` |
| `synthetic-input.parquet` | `45bba45b836be32abfd4a4ccc4e487d96340a752bca16692510847147acd9b12` |
| `expected-output.json` | `faf89998eeb0867eb9cb3034f14d97f865b5f2992ee2f1554bb0b8a9685b14e5` |

Do not regenerate or edit these files in the AWS task. `OCI_MANIFEST_DIGEST`
is added only after the exact accepted source is rendered as one reviewed
`linux/amd64` registry manifest.

## Required external evidence

Set all paths explicitly and keep them outside the repository and `/tmp`:

```bash
export CLOUD_ENV_FILE=/home/user/docker/Ray_terraform/.env
source scripts/load-cloud-env.sh aws

export AWS_TASK_B_REVIEW=/home/user/evidence/Ray_terraform/aws/goal-03-task-b/platform/source-89a89c5f03e1/plan-01/task-b-plan-review-receipt.json
export AWS_TASK_B_ACCEPTANCE=/home/user/evidence/Ray_terraform/aws/goal-03-task-b/platform/source-89a89c5f03e1/plan-01/apply-01/task-b-acceptance-receipt.json
export AWS_PLATFORM_OUTPUTS=/home/user/evidence/Ray_terraform/aws/goal-03-task-b/platform/source-89a89c5f03e1/plan-01/apply-01/platform-outputs.json
```

Use a fresh `AWS_EVIDENCE_DIRECTORY` for every operation. Never reuse a
partial directory. The scripts fail if the directory is a symlink, is under
the repository or `/tmp`, or already contains evidence.

## Read-only readiness

Set `DEPLOYMENT_ID`, the five common hashes, the reviewed OCI digest, and a
fresh evidence directory, then run:

```bash
make CLOUD=aws dummy-preflight
```

The preflight records current source identity, account, region, temporary
deployer-role assumption, EC2 standard-instance quota, live ECS-optimized AMI,
`t3.large` offering, protected buckets, platform network, backend object and
state version, ECR, exact S3 target prefixes, runner inventory, Scheduler,
SSM, IAM trust and publisher policy. It is blocked until the publisher can
read exactly the canonical `result-manifest.json`, bounded bootstrap log and
local handoff while retaining no arbitrary result read. Closure requires the
one exact inline role policy, no attached managed policy, and a results-bucket
resource policy containing no `Allow` statement.

The earlier saved platform plan `4d32fdbb...` is historical review evidence,
not reusable authorization. Replan the one-address publisher-policy delta
against current state, preserve the new binary/JSON/text renderings and stop
for authorization of that exact new plan.

## Three independent publications

Image, synthetic input and run spec are three mutations. For each kind set
`AWS_PUBLICATION_KIND` to `image`, `input`, or `run-spec` and use a fresh
evidence directory:

```bash
make CLOUD=aws dummy-publication-review
```

Image review additionally requires `AWS_SOURCE_IMAGE` and an exact
`AWS_OCI_MANIFEST_FILE` whose byte hash is `OCI_MANIFEST_DIGEST`. Review emits
one AWS-specific binding and the exact authorization sentence. Execute only
that one binding with:

```bash
export PUBLICATION_BUNDLE=/absolute/path/to/aws-KIND-publication.json
export PUBLICATION_BUNDLE_SHA256=...
export PUBLICATION_AUTHORIZATION=/absolute/path/to/publish-authorization.json
make CLOUD=aws dummy-publish
```

The image target is an absent content-addressed tag in immutable ECR. S3
objects use `If-None-Match: *`, provider checksums, content-addressed keys and
versioning. A failed or partial publication is preserved and is never retried
automatically.

## Runner saved plan and exact apply

After all three publications and a passing fresh preflight, set the immutable
run-spec version, current reviewed AMI, a future five-minute apply window and
the provider deadline:

```bash
export AWS_PREFLIGHT_SUMMARY=/absolute/path/to/readiness-summary.json
export AWS_RUN_SPEC_VERSION_ID=...
export AWS_AMI_ID=ami-...
export AWS_STARTED_AT_UTC=YYYY-MM-DDTHH:MM:SSZ
export AWS_DEADLINE_UTC=YYYY-MM-DDTHH:MM:SSZ
make CLOUD=aws dummy-plan
```

Planning seals a private source copy, backend binding, exact request,
OpenTofu data directory and an eight-create allowlisted `runner.tfplan` under
the external evidence directory. It never applies. Apply only the exact plan
within its frozen five-minute window:

```bash
export SAVED_PLAN=/absolute/path/to/runner.tfplan
export SAVED_PLAN_SHA256=...
export APPLY_AUTHORIZATION=/absolute/path/to/apply-authorization.json
make CLOUD=aws dummy-apply
```

The adapter applies the supplied binary without replanning and never retries.

## Bounded observation and trusted receipt

`dummy-observe` performs one point-in-time EC2, SSM, Scheduler and S3 snapshot.
It does not loop and does not infer terminal acceptance from VM liveness or
object presence.

Once the runner is terminal, prepare the trusted receipt without mutation:

```bash
AWS_RUNNER_OUTPUTS=/absolute/path/to/runner-outputs.json \
AWS_RUNNER_REQUEST=/absolute/path/to/runner-request.json \
AWS_EVIDENCE_DIRECTORY=/absolute/fresh/receipt-review \
scripts/aws/prepare-dummy-receipt.sh
```

The source identity assumes the bounded deployer, which then assumes the
trusted publisher outside the runner. Publisher reads are hard-coded to the
exact local handoff, bounded log and canonical result manifest. The script
validates them, reads EC2/Scheduler facts, and prepares control evidence, the
completion receipt and receipt bundle. It performs no upload.

After exact receipt-bundle authorization, publish with
`dummy-receipt-publish`. The publisher conditionally creates the hashed
control evidence and terminal receipt and records its STS identity, S3 version
and checksum. Both publication and `dummy-receipt-check` require the sealed
`AWS_RUNNER_REQUEST` and `AWS_RUNNER_OUTPUTS`; they reject non-success terminal
states as acceptance and reject any receipt that differs from those bindings.
An authenticated failed receipt is terminal with `terminal_acceptance:false`.
The check validates the recorded publisher identity and provider checksum
before independently retrieving that exact version and validating the final
bytes.

## Runner-only destroy

Use `dummy-destroy-plan` with the sealed original runner plan directory and
runner outputs. It accepts only eight deletes from the disposable runner root.
After exact destroy-plan authorization, `dummy-destroy` applies the supplied
binary without replanning. `dummy-post-destroy-check` verifies empty runner
state plus absent EC2/IAM/Scheduler resources while the three persistent S3
buckets and ECR remain. Only the exact provider not-found responses establish
absence; authentication, authorization, throttling and other API failures
block verification.

Terminal AWS acceptance requires the validated successful receipt and the
post-destroy proof. Until then report AWS as `NOT STARTED`, `PLANNED`,
`APPLIED`, `TERMINAL PASS`, or `TERMINAL FAIL`, and report point-in-time
liveness separately.
