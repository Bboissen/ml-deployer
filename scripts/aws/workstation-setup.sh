#!/usr/bin/env bash
# Bash 3.2 compatible: bootstrap without Python, cloud credentials or root.
set -euo pipefail
umask 077
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/scripts/aws/workstation-ui.sh"
manifest="$repo_root/scripts/aws/workstation-tools.lock.tsv"
requirements="$repo_root/scripts/aws/controller-requirements.lock"
prefix="${WORKSPACE_TOOLS_DIR:-$repo_root/.tools/aws-workstation}"
check_only=0
github=0
system_packages=0
fresh=0
debug=0
fail() { printf 'workstation-setup: %s\n' "$1" >&2; exit 2; }
log() {
  if [[ -t 2 ]] && ((!check_only && !debug)); then
    case "$1" in
      '[RUN] '*) ui_status run "${1#\[RUN\] }" ;;
      '[DONE] replaced previous installation '*) ui_status done 'Previous tools replaced' ;;
      '[DONE] '*) ui_status done "${1#\[DONE\] }" ;;
      'ready: '*) ui_status done 'Tools ready' ;;
      *) ui_status run "$1" ;;
    esac
  else printf 'workstation-setup: %s\n' "$1" >&2; fi
}
while (($#)); do
  case "$1" in
    --check) check_only=1 ;;
    --github) github=1 ;;
    --system-packages) system_packages=1 ;;
    --fresh) fresh=1 ;;
    --debug) debug=1 ;;
    --prefix) shift; (($#)) || fail '--prefix needs an absolute path'; prefix="$1" ;;
    --help) printf '%s\n' 'setup [--check] [--fresh] [--github] [--system-packages] [--debug] [--prefix ABSOLUTE_PATH]'; exit 0 ;;
    *) fail "unknown setup option $1; see setup --help" ;;
  esac
  shift
done
(( !check_only || !system_packages )) || fail '--check cannot install system packages'
(( !check_only || !fresh )) || fail '--check only inspects; use setup --fresh to rebuild'
# Ordinary directories, including ones with spaces, are fine. Reject traversal
# and the few characters that cannot be embedded safely in installer metadata.
[[ "$prefix" == /* ]] || fail 'choose an absolute --prefix'
prefix="${prefix%/}"
[[ -n "$prefix" && "$prefix" != *'/../'* && "$prefix" != */.. && "$prefix" != *'/./'* && "$prefix" != */. && "$prefix" != *'//'* ]] || fail 'prefix must not contain empty, . or .. segments'
[[ "$prefix" != *[\$\`\"\'\\\<\>\&\;\|]* && "$prefix" != *[[:cntrl:]]* ]] || fail 'prefix must not contain quotes, backslashes or $ ` < > & ; | characters'
physical() {
  # Resolve existing ancestors physically so symlinked homes and data mounts
  # work; the installer then owns and checks the real directory.
  local path="$1" rest='' resolved
  while [[ ! -d "$path" ]]; do rest="/$(basename "$path")$rest"; path="$(dirname "$path")"; done
  resolved="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved" != / ]] || resolved=''
  printf '%s%s\n' "$resolved" "$rest"
}
prefix="$(physical "$prefix")" || fail 'prefix parent directory is not accessible'
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
  *) fail "unsupported CPU architecture $(uname -m); pinned tools exist for x86_64 and arm64" ;;
esac
libc=''
case "$(uname -s)" in
  Linux)
    platform="linux-$arch"
    libc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    # The pinned AWS CLI and Python builds are dynamically linked against glibc.
    [[ "$libc" == glibc* ]] || fail "pinned Linux tools need glibc; this host reports '${libc:-no glibc}' (Alpine/musl is unsupported)"
    prerequisites=(curl tar unzip dpkg-deb)
    ;;
  Darwin)
    platform="darwin-$arch"
    libc="$(sw_vers -productVersion 2>/dev/null || true)"
    prerequisites=(curl tar unzip installer pkgutil)
    ;;
  *) fail "unsupported operating system $(uname -s); use Linux or macOS" ;;
esac
missing=()
for tool in "${prerequisites[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ -n "${missing[*]-}" ]]; then
  if ((system_packages)) && [[ "$platform" == linux-* ]] && command -v apt-get >/dev/null; then
    command -v sudo >/dev/null || fail 'sudo is missing; ask the host administrator to install curl ca-certificates unzip tar dpkg coreutils'
    sudo apt-get update >&2
    sudo apt-get install -y --no-install-recommends curl ca-certificates unzip tar dpkg coreutils >&2
    retry=(--prefix "$prefix")
    (( !github )) || retry+=(--github)
    (( !fresh )) || retry+=(--fresh)
    exec bash "$0" "${retry[@]}"
  fi
  if [[ "$platform" == linux-* ]]; then
    fail "missing OS tools (${missing[*]}); run ./workspace setup --system-packages on Ubuntu/Debian, or ask your administrator to install curl ca-certificates unzip tar dpkg coreutils"
  else
    fail "missing OS tools (${missing[*]}); install Apple Command Line Tools with xcode-select --install, finish the native dialog, then rerun setup"
  fi
fi
hash() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d ' ' -f 1
  else fail 'install sha256sum (Linux coreutils) or shasum (macOS)'; fi
}
fingerprint="$(printf '%s\n' "$(hash "$manifest")" "$(hash "$requirements")" "$platform" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -d ' ' -f 1)"
lock="$prefix/install.lock"
owner_pid=''
owner_host=''
read_lock_owner() {
  owner_pid=''; owner_host=''
  if [[ -f "$lock/owner" && ! -L "$lock/owner" ]]; then { read -r owner_pid; read -r owner_host; } < "$lock/owner" || true; fi
}
process_alive() { ps -p "$1" -o pid= 2>/dev/null | grep -q .; }
first_line() { "$@" 2>/dev/null | head -n 1 | cut -c1-80 || true; }
diagnostics() {
  log "debug: platform=$platform os=$(uname -s) arch=$(uname -m) libc='$libc'"
  log "debug: prefix=$prefix"
  log "debug: free=$(df -Pk "$1" | awk 'NR==2 {printf "%.1f GiB", $4/1048576}')"
  if [[ -L "$prefix/current" ]]; then
    local current; current="$(readlink "$prefix/current")"
    log "debug: current=$current"
    if [[ -f "$current/complete" ]]; then
      [[ "$(cat "$current/complete")" == "$fingerprint" ]] && log 'debug: pins=match' || log 'debug: pins=changed since installation'
    else log 'debug: pins=incomplete installation'; fi
    for tool in aws tofu uv gh session-manager-plugin; do
      [[ -e "$current/bin/$tool" ]] && log "debug: $tool: $(CHECKPOINT_DISABLE=1 first_line "$current/bin/$tool" $([[ "$tool" == tofu ]] && echo version || echo --version))" || log "debug: $tool: not installed"
    done
    [[ -x "$current/sdk/bin/python" ]] && log "debug: python: $(first_line "$current/sdk/bin/python" --version)" || log 'debug: python: not installed'
  else log 'debug: current=none'; fi
  if [[ -d "$lock" ]]; then
    read_lock_owner
    local alive=unknown
    if [[ "$owner_pid" =~ ^[0-9]+$ ]]; then process_alive "$owner_pid" && alive=yes || alive=no; fi
    log "debug: lock=held owner_pid=${owner_pid:-unknown} owner_host=${owner_host:-unknown} alive=$alive"
  else log 'debug: lock=none'; fi
}
if ((debug)); then
  probe="$prefix"; while [[ ! -d "$probe" ]]; do probe="$(dirname "$probe")"; done
  diagnostics "$probe"
fi
verify_failure=''
verify_runtime() {
  local release="$1" tool expected actual row_platform version url checksum
  verify_failure='pins changed since installation'
  [[ -f "$release/complete" && "$(cat "$release/complete")" == "$fingerprint" ]] || return 1
  while IFS=$'\t' read -r row_platform tool version url checksum; do
    [[ "$row_platform" == "$platform" ]] || continue
    [[ "$tool" != gh || "$github" == 1 ]] || continue
    verify_failure="$tool $version does not run or reports another version (host libc: ${libc:-unknown})"
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
  verify_failure='controller Python packages differ from the reviewed lock'
  "$release/sdk/bin/python" -I -B - "$requirements" <<'PY' >/dev/null 2>&1
import importlib.metadata, pathlib, re, sys
for name, version in re.findall(r'^([a-zA-Z0-9_-]+)==([^\s]+)', pathlib.Path(sys.argv[1]).read_text(), re.M):
    assert importlib.metadata.version(name) == version
import boto3, botocore, jsonschema
PY
}
if [[ -e "$prefix" ]]; then
  [[ -d "$prefix" && -f "$prefix/owner" && ! -L "$prefix/owner" && "$(cat "$prefix/owner")" == "aws-workstation-v1:$(id -u)" && -O "$prefix" ]] || fail "existing directory $prefix is not owned by this installer; choose another --prefix"
fi
previous=''
if [[ -L "$prefix/current" ]]; then
  current="$(readlink "$prefix/current")"
  [[ "$current" == "$prefix/releases/"* && "$current" != *'/../'* && -d "$current" && ! -L "$current" ]] || fail 'current tool directory points outside owned releases; choose another --prefix'
  if verify_runtime "$current"; then
    if ((!fresh)); then
      ((!check_only)) || log "ready: $platform tools in $prefix/current"
      ((check_only)) || log '[DONE] Managed tools verified; no installation or environment activation needed'
      exit 0
    fi
    log '[RUN] rebuilding verified managed tools (--fresh)'
  else
    ((!check_only)) || fail "managed tools need repair: $verify_failure; run ./workspace setup --fresh"
    log "managed tools need repair ($verify_failure); building a replacement"
  fi
  previous="$current"
elif [[ -e "$prefix/current" ]]; then
  fail 'current is not an installer-owned symlink; choose another --prefix'
fi
((!check_only)) || fail 'managed tools are not installed; run ./workspace setup'
mkdir -p "$prefix"
[[ -O "$prefix" && -w "$prefix" ]] || fail "$prefix is not writable by the current user; choose a user-owned --prefix"
[[ -f "$prefix/owner" ]] || printf 'aws-workstation-v1:%s\n' "$(id -u)" > "$prefix/owner"
claim_lock() { mkdir "$lock" 2>/dev/null && printf '%s\n%s\n' "$$" "$(uname -n)" > "$lock/owner"; }
if ! claim_lock; then
  # Recover only a lock whose owning process verifiably exited on this host.
  read_lock_owner
  if [[ "$owner_pid" =~ ^[0-9]+$ && "$owner_host" == "$(uname -n)" ]]; then
    if process_alive "$owner_pid"; then
      if ps -p "$owner_pid" -o args= 2>/dev/null | grep -q 'workstation-setup\|install-release\|install.sh'; then
        fail "another setup (process $owner_pid) is installing into $prefix; wait for it to finish"
      fi
      fail "process $owner_pid still holds $lock but is not a setup; if it is unrelated, remove the lock: rm -r '$lock'"
    fi
    log "recovering install.lock abandoned by exited process $owner_pid"
    rm -rf "$lock"
    claim_lock || fail 'install.lock reappeared; another setup is starting'
  else
    fail "$lock has no verifiable owner on this host; when no setup runs anywhere, remove it: rm -r '$lock'"
  fi
fi
release=''
activated=0
scratch="$(mktemp -d "$lock/scratch.XXXXXX")"
cleanup() {
  result=$?
  if [[ -n "$release" ]] && (( !activated )); then rm -rf "$release"; fi
  rm -rf "$lock"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ "$(df -Pk "$prefix" | awk 'NR==2 {print $4}')" -ge 2097152 ]] || fail "tool installation needs 2 GiB free under $prefix"
mkdir "$scratch/downloads"
mkdir -p "$prefix/releases"
[[ ! -L "$prefix/releases" ]] || fail 'installer directories must not be symlinks'
# Interrupted installations leave installer-owned directories without a
# completion marker; remove only those, never the selected runtime.
for leftover in "$prefix"/releases/*; do
  [[ -d "$leftover" && ! -L "$leftover" && ! -f "$leftover/complete" && "$leftover" != "$previous" ]] || continue
  log "removing incomplete installation $leftover"
  rm -rf "$leftover"
done
release="$(mktemp -d "$prefix/releases/$fingerprint.XXXXXX")"
mkdir "$release/bin"
export UV_CACHE_DIR="$scratch/uv-cache" UV_PYTHON_DOWNLOADS=never PYTHONDONTWRITEBYTECODE=1
while IFS=$'\t' read -r row_platform tool version url checksum; do
  [[ "$row_platform" == "$platform" ]] || continue
  [[ "$tool" != gh || "$github" == 1 ]] || continue
  [[ "$checksum" =~ ^[a-f0-9]{64}$ && "$url" == https://* ]] || fail 'invalid tool lock entry'
  archive="$scratch/downloads/$checksum"
  log "[RUN] installing $tool $version"
  curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 300 --retry 2 -o "$archive.part" "$url" \
    || fail "download of $tool $version failed; check network access and rerun setup"
  [[ "$(hash "$archive.part")" == "$checksum" ]] || fail "download checksum mismatch for $tool $version; nothing from this archive was executed; rerun setup"
  mv "$archive.part" "$archive"
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
        # The official bundle is self-contained; copying its dist directory
        # is what the vendor install script does, without its path limits.
        unzip -q "$archive" -d "$scratch/aws-installer"
        mv "$scratch/aws-installer/aws/dist" "$release/aws-cli"
        ln -s "$release/aws-cli/aws" "$release/bin/aws"
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
  rm -f "$archive"
  log "[DONE] $tool $version downloaded and unpacked"
done < "$manifest"
log '[RUN] Prepare the private Python runtime and locked packages (automatic)'
"$release/bin/uv" --quiet --no-config venv --python "$release/python/bin/python3.13" "$release/sdk" >&2
"$release/bin/uv" --quiet --no-config pip sync --python "$release/sdk/bin/python" --only-binary :all: --require-hashes --index-url https://pypi.org/simple "$requirements" >&2
log '[DONE] Private Python runtime prepared; do not activate it or edit shell settings'
printf '%s\n' "$fingerprint" > "$release/complete"
log '[RUN] Verify every pinned tool and Python package'
verify_runtime "$release" || fail "installed tools failed verification ($verify_failure); the previous installation, if any, remains selected"
log '[DONE] Every pinned tool and Python package verified'
ln -s "$release" "$lock/current"
"$release/sdk/bin/python" -I - "$lock/current" "$prefix/current" <<'PY'
import os, sys
os.replace(sys.argv[1], sys.argv[2])
PY
activated=1
rm -f "$release/AWSCLIV2.pkg" "$release/choices.xml"
if [[ -n "$previous" && "$previous" != "$release" && "$previous" == "$prefix/releases/"* && -d "$previous" && ! -L "$previous" ]]; then
  rm -rf "$previous"
  log "[DONE] replaced previous installation $previous"
fi
log "ready: $platform tools in $prefix/current; ./workspace selects them automatically"
