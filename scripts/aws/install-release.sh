#!/usr/bin/env bash
# Standalone Bash 3.2 installer. Download/extract/setup only; no cloud actions.
set -euo pipefail
umask 077
# package-release.py pins the published installer from shared/workspace/release.json.
version=''
prefix="${WORKSPACE_INSTALL_DIR:-$HOME/.local/share/aws-workspace}"
github=0
fresh=0
restore=0
fail() { printf 'aws-workspace-install: %s\n' "$1" >&2; exit 2; }
log() { printf 'aws-workspace-install: %s\n' "$1" >&2; }
while (($#)); do
  case "$1" in
    --version) shift; (($#)) || fail '--version requires a value'; version="$1" ;;
    --prefix) shift; (($#)) || fail '--prefix requires a value'; prefix="$1" ;;
    --github) github=1 ;;
    --fresh) fresh=1 ;;
    --restore) restore=1 ;;
    --help) printf '%s\n' 'install.sh [--version VERSION] [--prefix ABSOLUTE_PATH] [--github] [--fresh] [--restore]'; exit 0 ;;
    *) fail "unknown option $1; see --help" ;;
  esac
  shift
done
[[ -n "$version" ]] || fail 'use the packaged installer or pass --version VERSION'
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || fail 'invalid version'
[[ "$prefix" == /* ]] || fail 'choose an absolute --prefix'
prefix="${prefix%/}"
[[ -n "$prefix" && "$prefix" != *'/../'* && "$prefix" != */.. && "$prefix" != *'/./'* && "$prefix" != */. && "$prefix" != *'//'* ]] || fail 'prefix must not contain empty, . or .. segments'
[[ "$prefix" != *[\$\`\"\'\\\<\>\&\;\|]* && "$prefix" != *[[:cntrl:]]* ]] || fail 'prefix must not contain quotes, backslashes or $ ` < > & ; | characters'
physical() {
  local path="$1" rest='' resolved
  while [[ ! -d "$path" ]]; do rest="/$(basename "$path")$rest"; path="$(dirname "$path")"; done
  resolved="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved" != / ]] || resolved=''
  printf '%s%s\n' "$resolved" "$rest"
}
prefix="$(physical "$prefix")" || fail 'prefix parent directory is not accessible'
for tool in curl tar awk cmp; do command -v "$tool" >/dev/null || fail "missing prerequisite: $tool"; done
hash() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}
if [[ -e "$prefix" ]]; then
  [[ -d "$prefix" && ! -L "$prefix/owner" && -f "$prefix/owner" && -O "$prefix" && "$(cat "$prefix/owner")" == "aws-workspace-release-v1:$(id -u)" ]] || fail "existing directory $prefix is not installer-owned; choose another --prefix"
else
  mkdir -p "$prefix"
  printf 'aws-workspace-release-v1:%s\n' "$(id -u)" > "$prefix/owner"
fi
[[ "$(df -Pk "$prefix" | awk 'NR==2 {print $4}')" -ge 2097152 ]] || fail "installation needs 2 GiB free under $prefix"
lock="$prefix/install.lock"
# Same owner-tracked lock as the workstation installer; this file is published
# on its own, so the small recovery routine is repeated here.
claim_lock() { mkdir "$lock" 2>/dev/null && printf '%s\n%s\n' "$$" "$(uname -n)" > "$lock/owner"; }
if ! claim_lock; then
  owner_pid=''; owner_host=''
  if [[ -f "$lock/owner" && ! -L "$lock/owner" ]]; then { read -r owner_pid; read -r owner_host; } < "$lock/owner" || true; fi
  if [[ "$owner_pid" =~ ^[0-9]+$ && "$owner_host" == "$(uname -n)" ]]; then
    if ps -p "$owner_pid" -o pid= 2>/dev/null | grep -q .; then
      fail "another install (process $owner_pid) holds $lock; wait for it, or remove the lock if that process is unrelated"
    fi
    log "recovering install.lock abandoned by exited process $owner_pid"
    rm -rf "$lock"
    claim_lock || fail 'install.lock reappeared; another install is starting'
  else
    fail "$lock has no verifiable owner on this host; when no install runs anywhere, remove it: rm -r '$lock'"
  fi
fi
scratch="$(mktemp -d "$lock/scratch.XXXXXX")"
release_created=0
activated=0
cleanup() {
  result=$?
  if ((release_created && !activated)); then rm -rf "$release"; fi
  rm -rf "$lock"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$prefix/releases" "$prefix/bin"
[[ ! -L "$prefix/releases" && ! -L "$prefix/bin" ]] || fail 'installer directories cannot be symlinks'
name="aws-workspace-$version.tar.gz"
url="https://github.com/Bboissen/ml-deployer/releases/download/v$version"
curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --max-filesize 1024 -o "$scratch/checksum" "$url/$name.sha256" \
  || fail "release $version checksum download failed; check the version and network access"
read -r checksum filename < "$scratch/checksum"
[[ "$checksum" =~ ^[a-f0-9]{64}$ && "$filename" == "$name" ]] || fail 'release checksum metadata malformed'
curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --max-filesize 20971520 -o "$scratch/archive" "$url/$name" \
  || fail "release $version archive download failed; rerun the installer"
[[ "$(hash "$scratch/archive")" == "$checksum" ]] || fail 'release checksum mismatch; nothing was installed; rerun the installer'
tar -tzf "$scratch/archive" > "$scratch/entries"
awk -v top="aws-workspace-$version/" 'index($0,top)!=1 || $0 ~ /(^|\/)\.\.?($|\/)/ {exit 1}' "$scratch/entries" || fail 'release archive path rejected'
tar -tvzf "$scratch/archive" | awk 'substr($1,1,1)!="-" {exit 1}' || fail 'release archive must contain only regular files'
tar -xzf "$scratch/archive" -C "$scratch"
release="$prefix/releases/$version"
if [[ -e "$release" ]]; then
  [[ -d "$release" && ! -L "$release" && -f "$release/.release-sha256" && ! -L "$release/.release-sha256" && "$(cat "$release/.release-sha256")" == "$checksum" ]] || fail 'existing version differs; preserve it and choose a new version'
  # Compare against the newly verified archive before executing existing code.
  # Runtime tools and operation evidence are retained alongside these files.
  restored=0
  while IFS= read -r entry; do
    relative="${entry#aws-workspace-$version/}"
    candidate="$release/$relative"
    parent="$candidate"
    while [[ "$parent" != "$release" ]]; do
      [[ ! -L "$parent" ]] || fail 'installed release source cannot be symlinked'
      parent="$(dirname "$parent")"
    done
    if [[ -f "$candidate" ]] && cmp -s "$scratch/$entry" "$candidate"; then continue; fi
    ((restore)) || fail "installed release source changed ($relative); rerun with --restore to put back the verified $version files, keeping evidence and tools"
    mkdir -p "$(dirname "$candidate")"
    cp "$scratch/$entry" "$candidate.restore" && mv "$candidate.restore" "$candidate"
    restored=$((restored + 1))
  done < "$scratch/entries"
  ((!restored)) || log "restored $restored verified source file(s) of $version; evidence and tools untouched"
else
  mv "$scratch/aws-workspace-$version" "$release"
  release_created=1
  printf '%s\n' "$checksum" > "$release/.release-sha256"
fi
setup_options=()
((!github)) || setup_options+=(--github)
((!fresh)) || setup_options+=(--fresh)
bash "$release/scripts/aws/workstation-setup.sh" ${setup_options[@]+"${setup_options[@]}"}
# Preserve each version and its evidence. Explicit version selection supports
# old operation recovery without rewriting recorded paths or deleting state.
cat > "$scratch/aws-workspace" <<SH
#!/usr/bin/env bash
set -euo pipefail
exec bash '$release/workspace' "\$@"
SH
chmod 0755 "$scratch/aws-workspace"
[[ ! -L "$prefix/bin/aws-workspace" && ! -d "$prefix/bin/aws-workspace" ]] || fail 'launcher destination cannot be a symlink/directory'
mv "$scratch/aws-workspace" "$prefix/bin/aws-workspace"
activated=1
printf 'Installed %s. Run %s/bin/aws-workspace --help\n' "$version" "$prefix"
