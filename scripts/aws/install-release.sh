#!/usr/bin/env bash
# Standalone Bash 3.2 installer. Download/extract/setup only; no cloud actions.
set -euo pipefail
umask 077
version=0.1.0-rc.1
prefix="${WORKSPACE_INSTALL_DIR:-$HOME/.local/share/aws-workspace}"
github=0
fail() { printf 'aws-workspace-install: %s\n' "$1" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --version) shift; (($#)) || fail '--version requires a value'; version="$1" ;;
    --prefix) shift; (($#)) || fail '--prefix requires a value'; prefix="$1" ;;
    --github) github=1 ;;
    --help) printf '%s\n' 'install.sh [--version VERSION] [--prefix ABSOLUTE_PATH] [--github]'; exit 0 ;;
    *) fail 'unknown option' ;;
  esac
  shift
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || fail 'invalid version'
[[ "$prefix" =~ ^/[A-Za-z0-9_./-]+$ && "$prefix" != / && "$prefix" != *'/../'* && "$prefix" != */.. && "$prefix" != *'/./'* && "$prefix" != */. && "$prefix" != *'//'* ]] || fail 'absolute prefix without traversal, spaces or metacharacters required'
parent="$prefix"
while [[ "$parent" != / ]]; do
  [[ ! -L "$parent" ]] || fail 'installation ancestors cannot be symlinks'
  parent="$(dirname "$parent")"
done
for tool in curl tar awk cmp; do command -v "$tool" >/dev/null || fail "missing prerequisite: $tool"; done
hash() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}
if [[ -e "$prefix" ]]; then
  [[ -d "$prefix" && ! -L "$prefix/owner" && -f "$prefix/owner" && -O "$prefix" && "$(cat "$prefix/owner")" == "aws-workspace-release-v1:$(id -u)" ]] || fail 'existing prefix is not installer-owned'
else
  mkdir -p "$prefix"
  printf 'aws-workspace-release-v1:%s\n' "$(id -u)" > "$prefix/owner"
fi
[[ "$(df -Pk "$prefix" | awk 'NR==2 {print $4}')" -ge 2097152 ]] || fail 'installation needs 2 GiB free'
mkdir "$prefix/install.lock" 2>/dev/null || fail 'another install holds install.lock; inspect before removing a stale lock'
scratch="$(mktemp -d "$prefix/install.lock/scratch.XXXXXX")"
release_created=0
activated=0
cleanup() {
  result=$?
  if ((release_created && !activated)); then rm -rf "$release"; fi
  rm -rf "$scratch"
  rmdir "$prefix/install.lock"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$prefix/releases" "$prefix/bin"
[[ ! -L "$prefix/releases" && ! -L "$prefix/bin" ]] || fail 'installer directories cannot be symlinks'
name="aws-workspace-$version.tar.gz"
url="https://github.com/Bboissen/Ray_terraform/releases/download/v$version"
curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --max-filesize 1024 -o "$scratch/checksum" "$url/$name.sha256"
read -r checksum filename < "$scratch/checksum"
[[ "$checksum" =~ ^[a-f0-9]{64}$ && "$filename" == "$name" ]] || fail 'release checksum metadata malformed'
curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --max-filesize 20971520 -o "$scratch/archive" "$url/$name"
[[ "$(hash "$scratch/archive")" == "$checksum" ]] || fail 'release checksum mismatch'
tar -tzf "$scratch/archive" > "$scratch/entries"
awk -v top="aws-workspace-$version/" 'index($0,top)!=1 || $0 ~ /(^|\/)\.\.?($|\/)/ {exit 1}' "$scratch/entries" || fail 'release archive path rejected'
tar -tvzf "$scratch/archive" | awk 'substr($1,1,1)!="-" {exit 1}' || fail 'release archive must contain only regular files'
tar -xzf "$scratch/archive" -C "$scratch"
release="$prefix/releases/$version"
if [[ -e "$release" ]]; then
  [[ -d "$release" && ! -L "$release" && -f "$release/.release-sha256" && ! -L "$release/.release-sha256" && "$(cat "$release/.release-sha256")" == "$checksum" ]] || fail 'existing version differs; preserve it and choose a new version'
  # Compare against the newly verified archive before executing existing code.
  # Runtime tools and operation evidence are retained alongside these files.
  while IFS= read -r entry; do
    relative="${entry#aws-workspace-$version/}"
    candidate="$release/$relative"
    parent="$candidate"
    while [[ "$parent" != "$release" ]]; do
      [[ ! -L "$parent" ]] || fail 'installed release source cannot be symlinked'
      parent="$(dirname "$parent")"
    done
    [[ -f "$candidate" ]] && cmp -s "$scratch/$entry" "$candidate" || fail 'installed release source changed; preserve its evidence and restore the reviewed source'
  done < "$scratch/entries"
else
  mv "$scratch/aws-workspace-$version" "$release"
  release_created=1
  printf '%s\n' "$checksum" > "$release/.release-sha256"
fi
setup_options=()
((!github)) || setup_options+=(--github)
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
