#!/usr/bin/env bash
# Bash 3.2 compatible: bootstrap without Python, cloud credentials or root.
set -euo pipefail
umask 077
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
manifest="$repo_root/scripts/aws/workstation-tools.lock.tsv"
requirements="$repo_root/scripts/aws/controller-requirements.lock"
prefix="${WORKSPACE_TOOLS_DIR:-$repo_root/.tools/aws-workstation}"
check_only=0
github=0
system_packages=0
fail() { printf 'workstation-setup: %s\n' "$1" >&2; exit 2; }
log() { printf 'workstation-setup: %s\n' "$1" >&2; }
while (($#)); do
  case "$1" in
    --check) check_only=1 ;;
    --github) github=1 ;;
    --system-packages) system_packages=1 ;;
    --prefix) shift; (($#)) || fail '--prefix needs an absolute path'; prefix="$1" ;;
    --help) printf '%s\n' 'setup [--check] [--github] [--system-packages] [--prefix ABSOLUTE_PATH]'; exit 0 ;;
    *) fail 'unknown setup option; see setup --help' ;;
  esac
  shift
done
(( !check_only || !system_packages )) || fail '--check cannot install system packages'
# Vendor AWS installers do not support whitespace. Reject shell/XML metacharacters
# too; all paths are still passed as individual arguments.
[[ "$prefix" =~ ^/[A-Za-z0-9_./-]+$ && "$prefix" != / && "$prefix" != *'/../'* && "$prefix" != */.. && "$prefix" != *'/./'* && "$prefix" != */. && "$prefix" != *'//'* ]] || fail 'choose an absolute prefix without spaces, dot traversal or metacharacters'
parent="$prefix"
while [[ "$parent" != / ]]; do
  [[ ! -L "$parent" ]] || fail 'installation prefix and ancestors must not be symlinks'
  parent="$(dirname "$parent")"
done
case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; arm64|aarch64) arch=aarch64 ;; *) fail 'unsupported architecture: use x86_64 or arm64' ;; esac
case "$(uname -s)" in
  Linux)
    platform="linux-$arch"
    libc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    [[ "$libc" =~ ^glibc\ 2\.([0-9]+)$ && "${BASH_REMATCH[1]}" -ge 35 ]] || fail 'Linux needs glibc >= 2.35; use Ubuntu 22.04/24.04 or Debian 12/13'
    prerequisites=(curl tar unzip git ssh dpkg-deb)
    ;;
  Darwin)
    platform="darwin-$arch"
    mac_version="$(sw_vers -productVersion)"
    [[ "$mac_version" =~ ^([0-9]+)\. && "${BASH_REMATCH[1]}" -ge 13 ]] || fail 'macOS 13 or newer is required'
    prerequisites=(curl tar unzip git ssh installer pkgutil)
    ;;
  *) fail 'unsupported OS: use Linux or macOS' ;;
esac
missing=()
for tool in "${prerequisites[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ "$platform" == darwin-* ]] && ! xcode-select -p >/dev/null 2>&1; then missing+=(Command-Line-Tools); fi
if ((${#missing[@]})); then
  if ((system_packages)) && [[ "$platform" == linux-* ]] && command -v apt-get >/dev/null; then
    command -v sudo >/dev/null || fail 'sudo is missing; ask the host administrator to install curl ca-certificates git openssh-client unzip tar dpkg coreutils'
    sudo apt-get update >&2
    sudo apt-get install -y --no-install-recommends curl ca-certificates git openssh-client unzip tar dpkg coreutils >&2
    retry=(--prefix "$prefix")
    (( !github )) || retry+=(--github)
    exec bash "$0" "${retry[@]}"
  fi
  if [[ "$platform" == linux-* ]]; then
    fail "missing OS tools (${missing[*]}); run setup --system-packages on Ubuntu/Debian, or ask your administrator to install curl ca-certificates git openssh-client unzip tar dpkg coreutils"
  else
    fail 'install Apple Command Line Tools with xcode-select --install, finish the native dialog, then rerun setup'
  fi
fi
hash() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d ' ' -f 1
  else fail 'install sha256sum (Linux coreutils) or shasum (macOS)'; fi
}
fingerprint="$(printf '%s\n' "$(hash "$manifest")" "$(hash "$requirements")" "$platform" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -d ' ' -f 1)"
verify_runtime() {
  local release="$1" tool expected actual row_platform version url checksum
  [[ -f "$release/complete" && "$(cat "$release/complete")" == "$fingerprint" ]] || return 1
  while IFS=$'\t' read -r row_platform tool version url checksum; do
    [[ "$row_platform" == "$platform" ]] || continue
    [[ "$tool" != gh || "$github" == 1 ]] || continue
    case "$tool" in
      aws) expected="aws-cli/$version "; actual="$("$release/bin/aws" --version 2>/dev/null)" || return 1 ;;
      tofu) expected="OpenTofu v$version"; actual="$(CHECKPOINT_DISABLE=1 "$release/bin/tofu" version 2>/dev/null)" || return 1 ;;
      uv) expected="uv $version "; actual="$("$release/bin/uv" --version 2>/dev/null)" || return 1 ;;
      python) expected="Python $version"; actual="$("$release/sdk/bin/python" --version 2>/dev/null)" || return 1 ;;
      ssm) expected="$version"; actual="$("$release/bin/session-manager-plugin" --version 2>/dev/null)" || return 1 ;;
      gh) expected="gh version $version "; actual="$("$release/bin/gh" --version 2>/dev/null)" || return 1 ;;
      *) return 1 ;;
    esac
    [[ "$actual" == "$expected"* ]] || return 1
  done < "$manifest"
  "$release/sdk/bin/python" -I -B - "$requirements" <<'PY' >/dev/null 2>&1
import importlib.metadata, pathlib, re, sys
for name, version in re.findall(r'^([a-zA-Z0-9_-]+)==([^\s]+)', pathlib.Path(sys.argv[1]).read_text(), re.M):
    assert importlib.metadata.version(name) == version
import boto3, botocore, jsonschema
PY
}
if [[ -e "$prefix" ]]; then
  [[ -d "$prefix" && -f "$prefix/owner" && ! -L "$prefix/owner" && "$(cat "$prefix/owner")" == "aws-workstation-v1:$(id -u)" && -O "$prefix" ]] || fail 'existing prefix is not owned by this installer; choose another --prefix'
fi
if [[ -L "$prefix/current" ]]; then
  current="$(readlink "$prefix/current")"
  [[ "$current" == "$prefix/releases/"* && "$current" != *'/../'* && -d "$current" && ! -L "$current" ]] || fail 'current tool directory points outside owned releases'
  if verify_runtime "$current"; then
    log "ready: $platform; managed tools override other PATH versions only inside this CLI"
    exit 0
  fi
elif [[ -e "$prefix/current" ]]; then
  fail 'current is not an installer-owned symlink; choose another --prefix'
fi
((!check_only)) || fail 'tools missing or pins changed; run setup (omit --check) to install the reviewed versions'
mkdir -p "$prefix"
[[ -O "$prefix" && -w "$prefix" ]] || fail 'prefix is not writable by the current user; choose a user-owned --prefix'
[[ -f "$prefix/owner" ]] || printf 'aws-workstation-v1:%s\n' "$(id -u)" > "$prefix/owner"
mkdir "$prefix/install.lock" 2>/dev/null || fail 'another setup holds install.lock; retry after it finishes, or inspect the lock before removing a stale lock'
release=''
activated=0
scratch="$(mktemp -d "$prefix/install.lock/scratch.XXXXXX")"
cleanup() {
  result=$?
  if [[ -n "$release" ]] && (( !activated )); then rm -rf "$release"; fi
  rm -rf "$scratch"
  rmdir "$prefix/install.lock"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ "$(df -Pk "$prefix" | awk 'NR==2 {print $4}')" -ge 2097152 ]] || fail 'tool installation needs 2 GiB free'
mkdir "$scratch/downloads"
mkdir -p "$prefix/releases"
[[ ! -L "$prefix/downloads" && ! -L "$prefix/releases" && ! -L "$prefix/uv-cache" ]] || fail 'installer directories must not be symlinks'
release="$(mktemp -d "$prefix/releases/$fingerprint.XXXXXX")"
mkdir "$release/bin"
export UV_CACHE_DIR="$scratch/uv-cache" UV_PYTHON_DOWNLOADS=never PYTHONDONTWRITEBYTECODE=1
while IFS=$'\t' read -r row_platform tool version url checksum; do
  [[ "$row_platform" == "$platform" ]] || continue
  [[ "$tool" != gh || "$github" == 1 ]] || continue
  [[ "$checksum" =~ ^[a-f0-9]{64}$ && "$url" == https://* ]] || fail 'invalid tool lock entry'
  archive="$scratch/downloads/$checksum"
  [[ ! -L "$archive" && ! -L "$archive.part" ]] || fail 'download cache must not contain symlinks'
  log "installing $tool $version"
  if [[ ! -f "$archive" ]]; then
    curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --retry 2 -o "$archive.part" "$url"
    [[ "$(hash "$archive.part")" == "$checksum" ]] || fail 'download checksum mismatch; nothing from this archive was executed'
    mv "$archive.part" "$archive"
  fi
  [[ "$(hash "$archive")" == "$checksum" ]] || fail 'cached download checksum mismatch; choose a fresh prefix or repair the exact cached file'
  case "$tool" in
    uv)
      mkdir "$release/uv"
      tar -xzf "$archive" --strip-components=1 -C "$release/uv"
      ln -s "$release/uv/uv" "$release/bin/uv"
      ;;
    python) tar -xzf "$archive" -C "$release" ;;
    tofu) unzip -q "$archive" tofu -d "$release/bin" ;;
    aws)
      if [[ "$platform" == linux-* ]]; then
        unzip -q "$archive" -d "$release/aws-installer"
        "$release/aws-installer/aws/install" --install-dir "$release/aws-cli" --bin-dir "$release/bin" >&2
      else
        # Official CurrentUserHomeDirectory installation, no sudo or shell edits.
        cp "$archive" "$release/AWSCLIV2.pkg"
        pkgutil --check-signature "$release/AWSCLIV2.pkg" >/dev/null
        cat > "$release/choices.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><array><dict><key>choiceAttribute</key><string>customLocation</string><key>attributeSetting</key><string>$release</string><key>choiceIdentifier</key><string>default</string></dict></array></plist>
XML
        installer -pkg "$release/AWSCLIV2.pkg" -target CurrentUserHomeDirectory -applyChoiceChangesXML "$release/choices.xml" >&2
        ln -s "$release/aws-cli/aws" "$release/bin/aws"
      fi
      ;;
    ssm)
      if [[ "$platform" == linux-* ]]; then
        dpkg-deb --extract "$archive" "$release/ssm-package"
        ln -s "$release/ssm-package/usr/local/sessionmanagerplugin/bin/session-manager-plugin" "$release/bin/session-manager-plugin"
      else
        unzip -q "$archive" -d "$release/ssm-package"
        ln -s "$release/ssm-package/sessionmanager-bundle/bin/session-manager-plugin" "$release/bin/session-manager-plugin"
      fi
      ;;
    gh)
      mkdir "$release/gh"
      if [[ "$platform" == linux-* ]]; then tar -xzf "$archive" --strip-components=1 -C "$release/gh"
      else
        unzip -q "$archive" -d "$release/gh"
        mv "$release/gh/gh_${version}_macOS_"*/bin "$release/gh/bin"
      fi
      ln -s "$release/gh/bin/gh" "$release/bin/gh"
      ;;
  esac
done < "$manifest"
"$release/bin/uv" --no-config venv --python "$release/python/bin/python3.13" "$release/sdk" >&2
"$release/bin/uv" --no-config pip sync --python "$release/sdk/bin/python" --only-binary :all: --require-hashes --index-url https://pypi.org/simple "$requirements" >&2
printf '%s\n' "$fingerprint" > "$release/complete"
verify_runtime "$release" || fail 'installed runtime differs from the reviewed pins; previous tools remain selected'
ln -s "$release" "$prefix/install.lock/current"
"$release/sdk/bin/python" -I - "$prefix/install.lock/current" "$prefix/current" <<'PY'
import os, sys
os.replace(sys.argv[1], sys.argv[2])
PY
activated=1
# Installer payloads are disposable; keep only user-installed runtime tools.
rm -rf "$release/aws-installer"
rm -f "$release/AWSCLIV2.pkg" "$release/choices.xml"
log "ready: $platform; use scripts/aws/workspace.sh to select these tools automatically"
