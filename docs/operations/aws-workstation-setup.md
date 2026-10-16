# AWS workstation setup

Bash bootstraps a machine without Python; Python then owns configuration,
immutable plans, expiry and cleanup. Users follow the
[first-use guide](../aws-setup-guide.html) via `make`; this page records how the
installer behaves, which checks it keeps, and how to repair it.

## Commands

```bash
./workspace guide [PROJECT.json]    # = make: interactive tools/project/sign-in setup plus companion
make remote                        # run on the server; print laptop tunnel and browser link
./workspace guide --read-only       # companion and readiness only; no questions, file writes or login
./workspace setup                   # install or verify the pinned tools; no login, no cloud calls
./workspace setup --check           # verify only; exit 2 with the repair command when something is wrong
./workspace setup --fresh           # rebuild the managed tools even when they verify
./workspace setup --github          # also install the GitHub CLI (private repositories)
./workspace setup --system-packages # Ubuntu/Debian: apt-get the missing OS tools with sudo first
./workspace setup --debug           # print bounded, redacted diagnostics before acting
./workspace doctor [PROJECT.json] [--debug] [--json]
```

Ordinary commands install missing managed tools automatically and select them
for that process only. The default prefix is `.tools/aws-workstation` inside
the checkout; `WORKSPACE_TOOLS_DIR` or `--prefix` chooses another user-owned
absolute directory. Spaces in paths are fine. Nothing edits shell startup files,
and a different AWS CLI or OpenTofu on the host PATH is left alone.

`make` keeps the guide running in the foreground until Ctrl+C. It opens a
graphical browser when available and always prints the URL and, for remote
use, an SSH forwarding command. The page refreshes readiness every 20 seconds
while visible and when focused, with doctor results cached for five seconds.
These checks can read the selected AWS identity and GitHub repository; they
never log in or change cloud resources. The default port is 8765, falling back
to the next free port through 8774; `WORKSPACE_GUIDE_PORT=9000 make` selects an
exact port. Interactive setup creates missing project files from your answers.

In an interactive terminal, `make` asks for the project names, named AWS profile,
supported region, mode/lifetime, repository/ref, setup/run commands, outputs and
dataset source. It validates answers against the existing project contract and
atomically writes a private project file; no copy command or editor is required.
Existing valid files are reused. Repairing an invalid existing file requires an
explicit answer and preserves optional resource/data limits; concurrent changes
and symlinked paths are refused. Interrupted answers leave no partial file.
Native sign-in is offered in the same terminal, using remote browser login over
SSH. Public repositories skip GitHub sign-in. An optional deployment review uses
the existing scope-bound confirmation; answering setup questions never launches
compute. `make FRESH=1` rebuilds tools and `make DEBUG=1` exposes diagnostic output.
Tool setup has one active spinner with elapsed time, then a completed check mark.
Terminal detection supports RTK's output relay; `NO_COLOR` disables colors.
Noninteractive output stays plain.

For SSH, keep the checkout on the server and run `make remote` there. It prints
a tunnel command using the connected server's address, port and current user.
Run that command from a separate laptop terminal outside SSH, keep it open,
then open the printed URL in the laptop's browser. Skip the tunnel when the
selected guide port is already forwarded. Answer setup questions in the original
SSH terminal. `remote` selects browser access from another device; installation
and configuration run on the repository host. Plain `make` detects SSH automatically too.
No laptop checkout, launcher or cloud tools are required. Under SSH the guide
uses its exact selected port rather than falling back silently to another port;
an occupied port is reported. To choose another port, set `WORKSPACE_GUIDE_PORT`
on the server and forward that port on the laptop. SSH sessions never launch a
browser on the server; the printed companion link is opened on the laptop.
The CLI presentation and connection-derived instructions follow Zelab's
installer patterns; this repository retains its live, read-only companion.

A new runtime becomes current only after every pinned binary ran and reported
its version and every Python package matched the hash lock. Failure leaves the
previously selected runtime in place. A rerun of a healthy installation
downloads nothing.

## Checks and flags inventory

| Check | Purpose | Decision |
| --- | --- | --- |
| glibc 2.35+, Ubuntu/Debian list | Guess binary compatibility | Removed. Requires only glibc (the pinned AWS CLI and Python are glibc builds); the binaries are run after extraction and a non-running tool names the host libc in its error |
| macOS 13+ | Guess binary compatibility | Removed; same run-and-verify capability check |
| Apple Command Line Tools, `xcode-select` | Provide git/curl | Removed; only missing tools are reported |
| `git`, `ssh` as installer prerequisites | Later controller needs | Advisory: `doctor` reports git for branch/tag resolution and ssh-keygen for private deploy keys when the project needs them |
| `curl`, `tar`, `unzip`, `dpkg-deb` (Linux) / `installer`, `pkgutil` (macOS) | Download and unpack | Retained with the exact package list and the `--system-packages` route |
| Prefix without spaces | Vendor AWS install script limitation | Removed; the bundle's `dist` directory is copied directly |
| Prefix ancestors not symlinks | Avoid writing through foreign links | Replaced by physical path resolution; the real directory is then owned and checked |
| Prefix owner marker, `current` inside `releases/` | Never overwrite a user's unrelated directory | Retained, actionable message |
| 2 GiB free | Downloads and venv | Retained |
| Download SHA-256 against the committed lock, HTTPS only, macOS pkg signature | Download integrity | Retained |
| `install.lock` | One installer at a time | Retained; the lock records its owner process and host, an exited owner on the same host is recovered automatically, a live or unverifiable owner is never removed |
| Version/package verification before activation | Working runtime | Retained; `--check` reports `run ./workspace setup --fresh` when a tool is corrupt |
| Release source compared to the verified archive (`install.sh`) | Installed code integrity | Retained; `--restore` writes back only changed files from the verified archive |
| `AWS_*` environment conflicts | Protect the selected account | Narrowed: `AWS_PROFILE`, `AWS_REGION` and other selection defaults are overridden by the project profile; credential, endpoint and role variables still conflict |
| Non-default profile, temporary credentials, no root | Protect the selected account | Retained |
| Interactive TTY for login | Browser consent/MFA | Retained |
| Help and `doctor` | Must work with nothing installed | Both run without tools or credentials |

## Managed versions and integrity

| Tool | Version |
| --- | --- |
| AWS CLI | 2.36.14 |
| OpenTofu | 1.12.3, matching all workspace roots |
| uv | 0.12.23 |
| Controller Python | 3.13.16, standalone build 20261009 |
| Session Manager plugin | 1.2.835.0, matching the native engine |
| boto3 / botocore | 1.43.109, matching the native engine |
| jsonschema | 4.25.1 |
| GitHub CLI, optional | 2.102.0 |

Every platform archive URL and SHA-256 is committed in
[`workstation-tools.lock.tsv`](../../scripts/aws/workstation-tools.lock.tsv)
for linux-x86_64, linux-aarch64, darwin-x86_64 and darwin-aarch64. Downloads
use HTTPS only, ignore user curl configuration and verify the committed hash
before anything is extracted or executed. macOS AWS CLI also passes
`pkgutil --check-signature` before Apple's installer. The
[controller dependency lock](../../scripts/aws/controller-requirements.lock)
pins every Python package with hashes and binary wheels only.

Official references: [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
[Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
[OpenTofu](https://opentofu.org/docs/intro/install/standalone/),
[standalone Python](https://github.com/astral-sh/python-build-standalone/releases/tag/20261009).

## Doctor

`./workspace doctor PROJECT.json` prints one line per check with `Ready`,
`To do` or `Not checked` and the exact next command:

- Managed tools: the same verification as `setup --check`.
- AWS identity: the project's profile. No profile yet gives the login command;
  an existing profile is checked with a bounded STS call through the CLI and the
  SDK. Ready states the account and ARN and notes that login does not prove
  infrastructure permissions.
- GitHub access: public HTTPS repositories resolve the ref with `git ls-remote`
  and need no login. Private `git@github.com:` repositories need the managed
  `gh`, `ssh-keygen` and an active GitHub login.
- Project config: schema, region, dataset path and size.
- Last operation: a saved review, a completed result with its output location,
  or an interrupted operation that needs `resume`.

Doctor never installs, logs in, registers keys or creates resources. Without a
project file it reports the tools, the project file as `To do` and the rest `Not checked`.

## Repair

`./workspace setup --fresh` rebuilds the managed runtime even when it verifies.
It reuses the committed pins, builds the replacement in a new directory, verifies
it, switches `current`, then removes the previous release. A failed rebuild
leaves the previous runtime selected. Logins, AWS profiles, GitHub credentials,
project files, shell settings, user-installed tools, state, saved plans,
authorizations, journals and receipts are not touched: they live outside the
tools prefix, under the AWS CLI's own directories or ignored `evidence/`.

Interrupted installations leave directories without a completion marker under
`releases/`; the next setup removes them. A lock left by a setup that exited is
recovered automatically on the same host. A lock whose owner is still running
is reported with its process ID; one with no verifiable owner is left in place
with the exact path to inspect.

If the launcher itself is broken in a source checkout, restore the tracked files:

```bash
git status --short
git checkout -- workspace scripts
./workspace setup --check
```

For a published release, rerun the same version's installer with `--restore`:
it downloads and verifies the archive checksum again, writes back only changed
release files, keeps `evidence/`, tools and other versions, then runs setup.
Older operations stay recoverable with their original version's launcher under
`releases/VERSION/`.

Repairing the installation is separate from an interrupted deployment. An
uncertain launch is reconciled with `./workspace PROJECT.json resume` or
`cancel`; fresh setup never repeats or alters an operation.

## Debug mode

`--debug` on `setup` or `doctor` prints bounded diagnostics to stderr: platform,
libc or macOS version, prefix, `current` target, whether the pins match, the
first version line of each tool, lock owner and liveness, free disk, the names
of `AWS_*`/`TF_*`/`GH_*` variables present (never their values), AWS profile
names (never their contents) and the last operation directory. Credentials,
private keys, tokens and raw browser login output are never captured.

## Assisted login

```bash
./workspace login --profile personal-dev --region us-east-1            # console browser login
./workspace login --profile team-dev --region us-east-1 --method sso   # IAM Identity Center
./workspace auth-check --profile personal-dev --region us-east-1
./workspace github-login                                               # private repositories only
```

Native `aws login` or `aws sso login` runs in your terminal and browser; the
controller never records credentials. The wrapper selects the project's pinned
CLI, rejects conflicting credentials, and checks that the CLI and SDK resolve
the same identity after sign-in. You can use `aws login --profile personal-dev
--region us-east-1` directly with a compatible CLI, then run the `auth-check`
command above.

For a browser on another device, add `--remote`. Console login prints an AWS
link and waits at `Enter the authorization code displayed in your browser:`.
Finish signing in in the browser, copy its authorization code, paste it into
that terminal prompt, and press Enter. IAM Identity Center instead uses its
device-code flow: enter the CLI's code in the browser. Native authentication
uses terminal input and output directly, including through RTK; input queued
before login starts is discarded so an extra Enter from setup cannot submit
an empty code. Ctrl+C cancels. If login has already exited, rerun it and use the
new link and code.

An existing console profile cannot silently become SSO; a credential-process or
source-profile profile is renewed with its own native login and then accepted
by `auth-check`. Ambient GitHub tokens are rejected by the assisted GitHub login.

## Verification

`make aws-automation-test` runs the installer, doctor and release suites offline
with mocked downloads for all four platforms, corrupt archives, non-running
binaries, failed rebuilds, spaces in paths, symlinked ancestors, stale, live and
uncertain locks, debug redaction and doctor states. Clean-host container
installation without preinstalled Python is recorded in the pull request that
changed the installer. Native macOS and Linux arm64 installation with real
browser login remain acceptance work; see the
[native acceptance scope](aws-native-acceptance.md).
