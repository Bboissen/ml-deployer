# AWS deployer quickstart

The short version of the [first-use guide](../aws-setup-guide.html): the
exact commands, in order. Native generic acceptance and release publication
remain pending; see [native acceptance scope](aws-native-acceptance.md).

## 1. Install

```sh
git clone https://github.com/Bboissen/ml-deployer.git
cd ml-deployer
make            # or ./workspace guide when make is not installed
```

`make` prepares the tools, signs you in to GitHub, asks for your GitHub
repository and dataset, derives every other setting, saves the configuration
and offers native AWS sign-in in the same terminal. To skip the questions:
`make REPO=owner/name DATASET=/path/to/data` (or
`./workspace guide PROJECT.json --repo owner/name --dataset PATH`, plus
`--profile NAME` when several native AWS profiles exist); only the browser
logins and the Deploy confirmation remain. Its companion at
`http://127.0.0.1:8765/` shows progress (over SSH, forward that port from your
laptop). It uses `~/aws-workspace/demo/project.json` unless you pass
`make PROJECT=/path/project.json`. Existing valid settings are reused.
When the deployment command finishes, `make` closes the companion and exits;
a failed deployment fails the target. To keep a companion open separately, run
`./workspace guide ~/aws-workspace/demo/project.json --read-only` (Ctrl+C to stop).
`make clean` removes interrupted tool builds; `make fclean` also removes the
installed managed tools, the project settings file and its AWS sign-in.
`make re` performs that full clean and restarts setup from the first question.
Stop any running guide first. The GitHub login, datasets and evidence are preserved.
`make DEBUG=1` shows diagnostics.
For a laptop connected over SSH, run `make` on the server. It detects SSH and prints
the tunnel command to run outside SSH on your laptop and the local browser
link. Answer setup questions in the original SSH terminal; all setup runs on
the repository host.
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
  https://github.com/Bboissen/ml-deployer/releases/download/vVERSION/install.sh -o install.sh
bash install.sh            # add --github to install the GitHub CLI now (make adds it otherwise)
rm install.sh
```

The archive checksum comes from the same official GitHub release over TLS; tool
archives and Python wheels use the committed hash locks. Then use
`$HOME/.local/share/aws-workspace/bin/aws-workspace` wherever `./workspace`
appears below.

## 2. Configure

`make` writes the project file from two answers, the GitHub repository and the
dataset (local path relative to the JSON file, `s3://` prefix or public HTTPS
file), and derives the rest:

| Field | Derived from |
| --- | --- |
| `repository.url` | GitHub visibility: private → `git@github.com:owner/name.git` (deploy key), public → `https://github.com/owner/name.git` |
| `repository.ref` | the repository's default branch |
| `project` | repository name, lowercased to `[a-z][a-z0-9-]`, 3–24 characters |
| `profile`, `region` | `AWS_PROFILE` or the only console/SSO profile (asked only among several; `ml-deployer` when none exists); `us-east-1` |
| `mode`, `maximum_runtime_minutes` | `job`, 60 (the schema maximum) |
| `commands`, `outputs.paths` | `make setup` / `make train`, `outputs` |

A rerun keeps existing values; edit the file (field reference:
[project configuration](aws-project-configuration.md)) or pass `--repo`,
`--dataset` or `--profile` to change them. The template is
`infra/aws/project.example.json`.

### Runtime contract

Your repository needs a `Makefile` with `setup` and `train` targets; setup and
`doctor` check this on the configured ref and show a To-do when one is missing.
On the instance the checkout runs, as a non-root user, `make setup` and then
`make train` with:

- `DATA_DIR`: the verified dataset, read-only;
- `OUTPUT_DIR`: `<checkout>/outputs`, persisted to S3 after the job.

```make
setup:
	python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
train:
	.venv/bin/python train.py --data "$(DATA_DIR)" --out "$(OUTPUT_DIR)"
```

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

## 4. GitHub access

Setup reads repository settings with the managed GitHub CLI after one browser
login (read-only API calls). Public repositories are cloned over HTTPS and need
nothing more. Private repositories use `git@github.com:owner/project.git`;
Deploy registers a read-only deploy key (repository admin permission required)
and stores the private key only in Secrets Manager.

```sh
./workspace setup --github
./workspace github-login
```

## 5. Doctor

```sh
./workspace doctor ~/aws-workspace/demo/project.json
```

Each line is `Ready`, `To do` or `Not checked` with the next command. The
`GitHub repository` line checks that the repository is reachable, that a
private repository uses its SSH URL and that the Makefile has the `setup` and
`train` targets. Repeat
until the last line is `Ready: review and deploy with …`. `--debug` adds
bounded, redacted diagnostics. `make` runs the same checks and shows them on the
companion page.

## 6. Review and Deploy

```sh
./workspace ~/aws-workspace/demo/project.json
./workspace ~/aws-workspace/demo/project.json status --wait 30
```

The command resolves account, zone, commit, dataset bytes, machine, price
estimate, retained resources and lifetime into an immutable scope, prints it and
asks once: type `deploy` to launch exactly that scope, or press Enter to stop
with no cloud change. The review also prints a 16-character scope hash. For
automation, run the review once without a terminal (it stops at
`review_required`), then rerun quoting that hash:

```sh
./workspace ~/aws-workspace/demo/project.json --authorization "approve scope 0123456789abcdef"
```

Nothing launches without the typed confirmation or an `--authorization` that
contains the hash of the exact scope it approves. Every saved OpenTofu plan is
inspected and bound to that one authorization. Stage progress prints as artifacts,
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
The workload and state buckets, the network, IAM boundaries and the expiry
guard are retained and may continue to cost money; deleting them is a separate
reviewed decision. Workspace mode keeps the machine until `cancel` or expiry;
`connect` opens its non-root terminal.

There are two buckets: the **state bucket** stores OpenTofu's infrastructure
records for later updates and recovery; the **workload bucket** stores both
datasets and results. The machine's permissions exclude the state bucket.
New guided foundations name them `<project>-state-<account>-<region>` and
`<project>-storage-<account>-<region>` so their purpose and owner are visible.

The dataset is the input selected during setup. Its source file/directory name
becomes a safe folder label, for example `datasets/training.csv/`. Each snapshot
is a folder named `<YYYY-MM-DDTHH-MM-SSZ>-<snapshot-id>/`, containing
`files/<original-relative-path>` and `manifest.json`. Original file names and
subdirectories are preserved. The manifest holds full checksums and exact S3
versions; unchanged data reuses the same snapshot without another upload.
Your commands read staged inputs through `DATA_DIR`.

Results are files your commands generate in `OUTPUT_DIR` (`outputs/` in the
checkout by default). Declared output paths are uploaded under
`results/<workspace>/<YYYY-MM-DDTHH-MM-SSZ>-<run-id>/files/`; `job.log` and
`execution.json` sit alongside `files/`. Dates are UTC, and full unique IDs
keep separate operations from colliding. Workspace permissions still allow
reading datasets and writing only that workspace's results. Deploy prints
the reviewed dataset/result locations before launch and the saved locations
afterward; use `output_uri` to open results directly.

Retained foundations keep their exact bucket names and layout, including
`projects/<project>/data/snapshots/<content-hash>/` and
`projects/<project>/workspaces/<workspace>/output/`. New runs add dated folders
within that existing output prefix. Existing results, manifests and recovery
receipts remain valid. An ordinary Deploy does not rename or replace storage;
moving existing contents to the readable layout needs a separately reviewed
migration. Lower-level root configurations default to the legacy layout;
new guided foundations explicitly select `storage_layout = "readable-v1"`.

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
