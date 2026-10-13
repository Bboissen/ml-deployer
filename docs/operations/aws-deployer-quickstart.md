# AWS deployer quickstart

The short version of the [first-use guide](../aws-setup-guide.html): the
exact commands, in order. Native generic acceptance and release publication
remain pending; see [native acceptance scope](aws-native-acceptance.md).

## 1. Install

```sh
git clone https://github.com/Bboissen/Ray_terraform.git
cd Ray_terraform
make            # or ./workspace guide when make is not installed
```

`make` prepares the tools, asks for project settings, saves the configuration,
and offers native sign-in in the same terminal. Its companion at
`http://127.0.0.1:8765/` shows progress (over SSH, forward that port from your
laptop). It uses `~/aws-workspace/demo/project.json` unless you pass
`make PROJECT=/path/project.json`. Existing valid settings are reused.
`make FRESH=1` rebuilds tools; `make DEBUG=1` shows diagnostics.
For a laptop connected over SSH, run `make remote` on the server. It prints
the tunnel command to run outside SSH on your laptop and the local browser
link. Use `make remote REMOTE_HOST=homelab` for your laptop's saved SSH alias;
answer setup questions in the original SSH terminal. The repo stays on the server.
The commands below are the optional manual equivalents of the guided flow.
On Ubuntu/Debian, when setup reports missing system packages, run
`./workspace setup --system-packages` (sudo) and then `make` again.

Linux with glibc (x86_64/arm64) and macOS (Intel/Apple Silicon) are supported;
there is no distribution or OS-version gate. The installer downloads hash-pinned
tools into a user-owned directory, edits no shell files and makes no cloud
calls. `./workspace --help` and `./workspace doctor` work before installation.

Once a release is published, its standalone installer replaces the clone:

```sh
curl -fsSL --proto '=https' --proto-redir '=https' \
  https://github.com/Bboissen/Ray_terraform/releases/download/vVERSION/install.sh -o install.sh
bash install.sh            # add --github for private repositories
rm install.sh
```

The archive checksum comes from the same official GitHub release over TLS; tool
archives and Python wheels use the committed hash locks. Then use
`$HOME/.local/share/aws-workspace/bin/aws-workspace` wherever `./workspace`
appears below.

## 2. Configure

```sh
mkdir -p ~/aws-workspace/demo
cp infra/aws/project.example.json ~/aws-workspace/demo/project.json
"${EDITOR:-nano}" ~/aws-workspace/demo/project.json
```

Set the profile, project/workspace names, dataset (local path relative to the
JSON file, `s3://` prefix or public HTTPS file), repository URL and ref, the
external project's setup/run argument arrays, output paths and a 15–60 minute
lifetime. Field reference: [project configuration](aws-project-configuration.md).

## 3. Sign in

```sh
./workspace login --profile my-workspace --region us-east-1      # add --method sso for Identity Center
./workspace auth-check --profile my-workspace --region us-east-1
```

Use a profile name other than `default` and temporary native identities, never
static keys. Login shows the account and ARN; it does not prove infrastructure
permissions, which Deploy checks against its saved plans. Ambient `AWS_PROFILE`
or `AWS_REGION` shell defaults are overridden by the project file.

If the browser shows `400 Bad Request` or another sign-in error, the link expired
or was already used: each link works once, for a few minutes, while the login
command still waits. Press Ctrl+C, rerun the login and use only the newly opened
page; add `--remote` if it still fails.

## 4. Private GitHub access, only when needed

Public repositories use an `https://github.com/owner/project.git` URL and need
no login. Private repositories use `git@github.com:owner/project.git`, the
managed GitHub CLI and one browser login; Deploy then registers a read-only
deploy key (repository admin permission required) and stores the private key
only in Secrets Manager.

```sh
./workspace setup --github
./workspace github-login
```

## 5. Doctor

```sh
./workspace doctor ~/aws-workspace/demo/project.json
```

Each line is `Ready`, `To do` or `Not checked` with the next command. Repeat
until the last line is `Ready: review and deploy with …`. `--debug` adds
bounded, redacted diagnostics.

## 6. Review and Deploy

```sh
./workspace ~/aws-workspace/demo/project.json
./workspace ~/aws-workspace/demo/project.json status --wait 30
```

The command resolves account, zone, commit, dataset bytes, machine, price
estimate, retained resources and lifetime into an immutable scope, prints it and
asks once: type `deploy` to launch exactly that scope, or press Enter to stop
with no cloud change. For automation:

```sh
./workspace ~/aws-workspace/demo/project.json \
  --authorization 'Approve the displayed account, resources, access, bytes, cost and lifetime scope'
```

Nothing launches without the confirmation or an explicit `--authorization`.
Every saved OpenTofu plan is inspected and bound to that one authorization; no
ARN, hash or state path is copied. Stage progress prints as artifacts,
foundation, repository, ingestion, prepare, launch, job, verify and cleanup
complete. A changed configuration or source needs a new review.

## 7. Outputs and cleanup

```sh
./workspace ~/aws-workspace/demo/project.json logs
```

The outcome reports infrastructure, setup exit, job exit, output persistence
and compute cleanup separately, with `output_uri` pointing at your declared
outputs and bounded logs in S3. `compute cleanup: success` plus
`outputs verified after compute deletion: True` confirms teardown. A second
Deploy with the same data reuses the retained versions without another upload.
Dataset, output and state buckets, the network, IAM boundaries and the expiry
guard are retained and may continue to cost money; deleting them is a separate
reviewed decision. Workspace mode keeps the machine until `cancel` or expiry;
`connect` opens its non-root terminal.

## Repair

```sh
./workspace setup --fresh                                   # rebuild managed tools; keeps logins, config, evidence
./workspace doctor ~/aws-workspace/demo/project.json --debug
./workspace ~/aws-workspace/demo/project.json resume        # interrupted deployment; never repeats a launch
```

A broken source checkout: `git checkout -- workspace scripts`. A broken
published install: rerun the same version's `install.sh --restore`. Details in
[workstation setup](aws-workstation-setup.md) and
[deploy operation](aws-deploy-operation.md).

## Release candidate

`shared/workspace/release.json` names `0.1.0-rc.1`. Build only from clean
committed source:

```sh
mkdir -p evidence/aws/releases
python3 -B scripts/aws/package-release.py evidence/aws/releases/candidate
```

The deterministic archive includes source hashes, commit ancestry and pinned
locks, and excludes `.git`, tools, caches, state, plans and credentials. The
installer keeps each version and its evidence; reinstalling the same version
preserves state and receipts. CI installs the pinned runtime on Ubuntu 24.04 and
macOS 14 and runs the mocked suites with read-only permissions and no cloud
credentials. Publishing a release is an owner decision after the named native
acceptance cases pass.
