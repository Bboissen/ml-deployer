# AWS deployer release candidate

The source implements the AWS journey. Native generic acceptance and release
publication remain pending. Historical PR24 native receipts establish only the
bounded private fixture route. GCP/Azure adapters and hosted execution are future
work. Do not use a draft source implementation as evidence of production readiness.

## Install and authenticate

Supported first-release hosts are Linux with glibc 2.35+ and macOS 13+, x86_64
or arm64. Linux needs curl, tar, unzip, Git, OpenSSH and dpkg; macOS needs Apple
Command Line Tools. The installer reports the exact missing prerequisites.
Account setup, MFA, billing and organization permissions remain owner actions.

Until a release is published, check out the accepted source branch and run:

```sh
git clone https://github.com/Bboissen/Ray_terraform.git
cd Ray_terraform
git switch refactor/deployer-audit
./workspace setup --github
```

After an approved `v0.1.0-rc.1` release is published, its standalone installer
supports this path without a source Git checkout:

```sh
curl -fsSL --proto '=https' --proto-redir '=https' \
  https://github.com/Bboissen/Ray_terraform/releases/download/v0.1.0-rc.1/install.sh \
  -o install-aws-workspace.sh
bash install-aws-workspace.sh --github
rm install-aws-workspace.sh
```

The archive checksum comes from the same versioned official GitHub release over
TLS; it provides corruption detection within that publisher trust, not an
independent signature. Tool archives and Python wheels use the committed hash
locks. Installation changes no shell profile and makes no account API calls.
Use `$HOME/.local/share/aws-workspace/bin/aws-workspace` for a published install,
or `./workspace` for a source checkout, as the CLI below.

```sh
./workspace login --profile temporary --region us-east-1
./workspace github-login
./workspace auth-check --profile temporary --region us-east-1
```

Use temporary native identities, not permanent AWS keys. The source operator
needs existing permission to manage its own scoped terminal grant. The routine
deployer cannot change operator IAM policies; it cannot grant that authority
to itself. An ordinary IAM user
with temporary credentials or owner-managed role can be resolved; reserved SSO
roles need the owner-managed role route. AWS login and GitHub login do not prove
VM repository grants. Private repositories require permission to register a
scoped read-only deploy key and create its native secret, or an already recorded
matching owned credential. Private keys stay in Linux tmpfs/macOS RAM disks and
Secrets Manager, outside OpenTofu inputs/state and logs.

## Configure, review and Deploy

Copy `infra/aws/project.example.json` to a project directory outside the source
tree (a published copy lives in `releases/VERSION/infra/aws/`). Set the explicit
profile, credential-free repository/ref, dataset path/URI, setup/run argv, output
paths and lifetime. The supported toolbox is `cpu-python-v1` in `us-east-1`;
selection keeps the most RAM within supported sizes, current regional quota,
offering and the optional `resources.maximum_hourly_usd`. Set byte ceilings for
dataset transfer and output persistence. Dataset paths are relative to the JSON
file, and may contain spaces. Local directories, same-region S3 object/prefixes
and public HTTPS files with strong ETags and known size are supported. Signed
URLs, private HTTP, symlinks, special files and cross-region S3 are rejected.

```sh
./workspace /absolute/project/project.json
```

Review the displayed account/operator, region/zone, repository commit, source
bytes/hash, target namespaces, retained resources, selected EC2 quote, additional
fee categories and absolute lifetime policy. Without authorization this command
makes no mutation. To bind that saved scope and proceed:

```sh
./workspace /absolute/project/project.json \
  --authorization 'Approve the displayed account, resources, access, bytes, cost and lifetime scope'
./workspace /absolute/project/project.json status --wait 30
./workspace /absolute/project/project.json logs
```

Deploy is the default command; an explicit `deploy` verb remains supported.
`./workspace --help` runs without downloading tools.
No ARNs, secret versions, foundation hashes or state paths need to be copied.
Saved plans are still inspected and individually bound to that task before
apply. Changes outside the selected scope stop. Dataset ingestion and exact
version/checksum verification finish before compute. Job mode runs setup and
entrypoint every time as `workspace`, then transfers declared outputs and bounded
logs. The repository owns reading the selected dataset manifest and its exact
versions using `DATA_MANIFEST_URI`, `DATA_MANIFEST_VERSION_ID` and
`DATA_MANIFEST_SHA256`; output declarations do not imply checkpoint guarantees.

Success requires independent output verification after compute teardown. Setup,
job, output transfer and cleanup remain separate fields. A second Deploy with
the same data verifies and reuses retained native versions. Workspace mode runs
setup only; `connect` opens the non-root terminal, and `cancel` or the absolute
provider expiry ends it. `cancel` records intent; `resume` reconciles recorded
ownership and never repeats an uncertain launch/command. See
[operation recovery](aws-deploy-operation.md) for bounded behavior and gaps.

## Existing foundation IAM update

Old foundations that allowed the deployer to change operator permissions are
blocked before compute launch. Keep the generated runtime configuration and
workspace directory from that operation; prepare the access update with:

```sh
./workspace /absolute/operation/runtime.json plan /absolute/operation/workspace access
```

This uses the existing foundation state. Inspect `access/plan.json` and its
`review.json`, then apply the exact review hash through the existing `apply`
command. The allowed IAM update removes the operator-management grant and adds
an explicit denial for those principals. Public repositories need no Git secret
for this update. It preserves resource addresses and all other foundation inputs.
Use the resulting captured foundation outputs for the next operation; never
edit historical reviews, authorization records or saved plans to bypass the gate.

## Release and evidence retention

Build only from clean committed source:

```sh
mkdir -p evidence/aws/releases
python3 -B scripts/aws/package-release.py evidence/aws/releases/candidate
```

The deterministic archive includes source hashes, commit ancestry and pinned
locks; it excludes `.git`, tools, caches, state, plans and credentials. The
installer keeps each version and its evidence. Reinstalling the same version
preserves state and receipts. Changing versions selects another code/evidence
directory: recover older operations with the same original version before any
upgrade. Automatic migration/adoption of another version's evidence is deferred;
the controller refuses same-name unowned foundation reuse. Never delete release
directories with real evidence or active expiry responsibilities.

CI installs the pinned workstation runtime on Ubuntu 24.04 and macOS 14, runs
the default mocked journey/policy suites and optionally builds candidate assets.
CI has read-only repository permissions and no cloud credential/OIDC grants.
The current source checks are recorded in the draft PR; new CI jobs and native
clean-host campaigns must pass before publishing or advertising acceptance.
