# AWS workstation setup

This installer extends the existing Python controller. Bash bootstraps a machine
without Python; Python retains configuration, immutable plans, expiry and cleanup.
This milestone builds on PR27. It installs local tools and assists native login.
Generic project deployment remains under implementation.

## Install and check

From this checkout, run:

```bash
bash scripts/aws/workspace.sh setup
bash scripts/aws/workspace.sh setup --check
```

Ordinary CLI commands install missing managed tools automatically and select
them for that process. `setup --check` checks the installed pins without downloads,
package installation or login. A different AWS CLI/OpenTofu on the host PATH is
preserved; the controller selects its own tools. Nothing edits shell startup files.

The default user-owned prefix is `.tools/aws-workstation` in this checkout. For a
checkout/home path containing spaces, choose a prefix without whitespace:

```bash
export WORKSPACE_TOOLS_DIR=/absolute/user-owned/path/aws-workstation
bash scripts/aws/workspace.sh setup
```

AWS's vendor installers do not support whitespace in installation paths. A
foreign prefix, symlink ancestor or concurrent install stops with a repair
message. Downloads and failed installation directories stay in the owned prefix.
A new runtime becomes current only after every tool and Python package passes
its version check. Failure preserves the previously selected runtime. A rerun
of a healthy installation does not download or replace it.

## Host matrix and prerequisites

| Host | Architectures | Required native tools |
| --- | --- | --- |
| Linux, glibc >= 2.35; Ubuntu 22.04/24.04 and Debian 12/13 are reference distributions | x86_64, aarch64 | Bash, curl, tar, unzip, Git, OpenSSH client, dpkg-deb, SHA-256 utility |
| macOS >= 13 | Intel x86_64, Apple arm64 | Bash, curl, tar, unzip, Git, OpenSSH client, installer, pkgutil, shasum; Apple Command Line Tools |

Linux requires Debian package extraction for the pinned Session Manager plugin;
musl/Alpine and Windows are unsupported. RTK is optional for end users. Guest
toolbox dependencies are separate from workstation dependencies.

On Ubuntu/Debian, missing native tools can be installed through the signed OS
repositories when explicitly requested:

```bash
bash scripts/aws/workspace.sh setup --system-packages
```

This runs `sudo apt-get update` and installs only `curl ca-certificates git
openssh-client unzip tar dpkg coreutils` when prerequisites are missing. The package manager may
need the user's sudo password. Without sudo, the installer gives the exact
package list for the administrator. Native OS packages follow that distribution's
security updates; they are not portable binary pins.

On macOS, run `xcode-select --install` if the installer reports missing Command
Line Tools, finish Apple's native dialog and rerun setup. The managed downloads
use the user prefix; AWS CLI uses Apple's current-user package installation.

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
[`workstation-tools.lock.tsv`](../../scripts/aws/workstation-tools.lock.tsv).
Downloads use HTTPS only, ignore user curl configuration and verify the committed
hash before extraction or execution, including cached downloads. macOS AWS CLI
also runs `pkgutil --check-signature` before Apple's installer. Tool hashes come
from official release metadata or the version-specific official AWS artifact;
installer execution never trusts a downloaded checksum file alone.

The [controller dependency lock](../../scripts/aws/controller-requirements.lock)
pins every Python package and allows binary wheels only with required hashes.
It includes the CRT extra needed by Boto3 for console login. Validation/example
dependencies remain in `shared/workspace/requirements.lock`; they are not installed
as project dependencies. External repositories still own their setup/run commands.

Official installation references: [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
[Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
[OpenTofu](https://opentofu.org/docs/intro/install/standalone/),
[standalone Python](https://github.com/astral-sh/python-build-standalone/releases/tag/20261009),
[Boto3 console login and CRT](https://docs.aws.amazon.com/boto3/latest/guide/credentials.html).

## Assisted login

Choose an explicit non-default profile. For console credentials:

```bash
bash scripts/aws/workspace.sh login --profile personal-dev --region us-east-1
```

The native `aws login` command opens the browser; the user selects the account
and completes MFA/consent. Use `--remote` when authentication happens on another
device. Existing console profiles are renewed; the AWS CLI manages its native
login cache. No static access-key setup is offered.

For an IAM Identity Center account:

```bash
bash scripts/aws/workspace.sh login --profile team-dev --region us-east-1 --method sso
```

A new SSO profile starts native `aws configure sso`; an existing SSO profile goes
straight to `aws sso login`. The AWS CLI asks for the account owner's start URL,
SSO region and permitted account/role. `--remote` selects native device-code flow.
Login cannot silently change a console profile into SSO or renew a credential
process/source-role profile through the wrong authentication method. Renew those
profiles through their original native login.

After login, or to check a returning session:

```bash
bash scripts/aws/workspace.sh auth-check --profile personal-dev --region us-east-1
```

The check reuses the existing profile/environment boundary and compares bounded
STS principal observations from the CLI and SDK (independent sessions of the
same assumed role are equivalent). Conflicting credentials/endpoints,
static-key profiles, expired sessions, root identity and mismatches stop clearly.
Only account/ARN metadata is returned; raw credential-process or provider errors
are redacted. Browser/device URLs stay in the interactive native login terminal.
The installer never records login output or exports credentials into evidence.

This check reports backend/provider identity as pending: the existing native
deployment checks them during foundation/saved-plan preflight. Login success
does not grant infrastructure permissions or authorize a deployment. SSO policy
generalization and macOS RAM-backed key preflight remain separate controller work.

Optional GitHub browser authorization:

```bash
bash scripts/aws/workspace.sh setup --github
bash scripts/aws/workspace.sh github-login
```

The optional CLI is installed automatically by `github-login`. Native GitHub CLI
owns browser consent and credential storage. Ambient GitHub tokens are rejected
by this assisted route. Private runtime access/deploy-key registration remains
the next onboarding milestone; a workstation login alone does not grant the VM
repository access.

## Verification and remaining acceptance

`make aws-workstation-test WORKSPACE_PYTHON=/path/to/validation/python` exercises
the four platform paths and failure boundaries offline. Existing scaffold checks
include this suite. `WORKSPACE_PYTHON` is an explicit developer/test runtime
override that bypasses automatic workstation installation; normal users omit it.

Verified locally: real Linux x86_64 installation; clean Ubuntu 24.04 container
installation as a non-root user without prior Python/AWS CLI/OpenTofu; rerun and
check-only behavior; optional GitHub CLI; preserved profile and shell settings.
Offline checks cover both architectures on Linux/macOS, bad download hashes,
failed signatures/upgrades, foreign prefixes, missing privileges, concurrency,
expired login, identity mismatch and login-method conflicts.

Native macOS/arm64 installation, browser login and the complete generic AWS Deploy
journey remain acceptance work. This milestone performs no cloud provisioning,
project dependency execution or dataset transfer. Next controller work is
foundation/access onboarding, dataset ingestion and generic execution/results.
