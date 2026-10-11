#!/usr/bin/env bash
# Run by the connected non-root workspace user, never cloud-init.
set -euo pipefail
[[ "$EUID" != 0 ]] || { echo 'Run this as workspace.' >&2; exit 2; }
[[ $# == 3 ]] || { echo 'Usage: clone-project.sh HTTPS_REPOSITORY FULL_COMMIT DIRECTORY' >&2; exit 2; }
[[ "$1" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+(\.git)?$ ]] || exit 2
[[ "$2" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ ! -e "$3" && ! -L "$3" ]] || { echo 'Destination already exists.' >&2; exit 2; }
git init -- "$3"
git -C "$3" remote add origin "$1"
git -C "$3" fetch --no-tags --depth=1 origin "$2"
git -C "$3" checkout --detach "$2"
[[ "$(git -C "$3" rev-parse HEAD)" == "$2" ]]
uv venv --python /usr/bin/python3.13 "$3/.venv"
printf 'Cloned reviewed revision. Install dependencies using the external repository instructions in %s/.venv.\n' "$3"
