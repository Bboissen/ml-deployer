# AWS OpenTofu roots

AWS uses three independent flat root modules:

- `bootstrap/` creates only the protected S3 remote-state bucket from local
  state;
- `platform/` owns persistent storage, ECR, networking and IAM boundaries;
- `runner/` owns one disposable EC2 runner, its per-deployment identity and its
  independent provider-side deadline.

Each root pins OpenTofu `1.12.3` and `hashicorp/aws` `6.61.0` and commits its own
dependency lock file. Provider configuration remains visible in each root.
There are no shared AWS resource modules.

The runner accepts the provider-neutral fields in one closed `runner_request`
object. This preserves the shared contract names; an object is required because
`provider` is a reserved top-level variable name in OpenTofu.

The platform emits a closed AWS binding object and its canonical OpenTofu JSON
SHA-256. The runner recomputes that hash and refuses any object that does not
exactly match its account, region, distinct state/data/results buckets,
subnet, no-ingress security group, ECR repository, runtime and deadline
boundaries, and receipt publisher inputs. The external S3 backend remains separately configured, while
the runner binds its expected bucket and deterministic key as reviewed inputs.
The request SHA-256 is derived inside the runner from `jsonencode` of the closed
request; offline tests prove it equals the normative `jq -cS` request hash.

## Safety boundary

These files are an offline scaffold. They do not authorize initialization
against a real backend, planning, applying, importing, state movement or cloud
mutation. The backend examples contain placeholders and must be copied outside
the repository and reviewed before use. Never place credentials in backend
configuration or variable files.

The bootstrap root intentionally has no backend block. Its one-time local state
must be retained as evidence until the protected remote backend is accepted.
The platform and runner roots declare empty S3 backend blocks and require
external backend configuration with native `use_lockfile = true`.

Validate without configuring a backend:

```bash
for root in infra/aws/bootstrap infra/aws/platform infra/aws/runner; do
  tofu -chdir="$root" init -backend=false
  tofu -chdir="$root" validate
done
bash tests/aws/test-scaffold.sh
```

Provider downloads may occur during `init -backend=false`; no AWS API is
contacted by these commands.

For a real Task B plan, run the evidence-bound plan and IAM contract checks via
`make aws-platform-plan-test PLAN_JSON=... REVIEW_RECEIPT=...`. After an
explicitly authorized apply, `make aws-platform-live-check
REVIEW_RECEIPT=... PLATFORM_OUTPUTS=... AWS_PROFILE=...` performs only read-only
AWS inventory and IAM simulation calls. The full gated procedure is documented
in [AWS persistent-platform acceptance](../../docs/operations/aws-platform-acceptance.md).

The platform creates a neutral OpenTofu deployer role for routine disposable
runner operations. Its trust is limited to reviewed temporary-login principals,
its state access is limited to the AWS runner prefix, and it may create only
runner-prefixed IAM roles carrying the accepted runtime or deadline boundary.
It cannot edit its own role, the persistent boundaries or the receipt publisher.
The runner provider assumes this exact account- and prefix-bound role; the broad
setup profile is used only to obtain the temporary source session.

The workload identity may conditionally create only its private local receipt
handoff below `runs/<deployment>/control-input/`. It cannot write the final
`control/` namespace. The distinct receipt publisher can read that handoff and
the bounded bootstrap log, enrich them with provider facts, and conditionally
create final control evidence and the terminal receipt.

The receipt publisher receives only `ec2:DescribeInstances` plus scoped
`scheduler:GetSchedule` for provider lifecycle and independent deadline facts,
and read access to the exact bounded bootstrap-log, local receipt handoff and
`runs/*/results/result-manifest.json` patterns. It cannot read arbitrary result
objects.

Runner apply is accepted only from `started_at_utc` through the derived
`started_at_utc + 5m` latest-apply boundary. The deadline must be after that
window and within the request's maximum runtime measured from the reviewed
start. A plan may be prepared earlier, but applying early or after the bounded
window fails closed.

Both the guest shutdown behavior and the independent EventBridge Scheduler
deadline terminate the disposable instance. The deadline role has a separate
maximum-permissions boundary and may terminate only project-tagged runners.

The instance requires IMDSv2 tokens and uses AWS's documented two-hop response
limit for a containerized workload. The role itself is deployment-scoped and
bounded; no credential is placed in user data or passed into the container.
