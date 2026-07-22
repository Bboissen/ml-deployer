#!/usr/bin/env bash
set -euo pipefail

if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

PREFIX="${LOCAL_VM_PREFIX:-ray-lab-worker}"

if ! command -v multipass >/dev/null; then
  echo "multipass is not installed; nothing to destroy via this script" >&2
  exit 0
fi

for name in $(multipass list --format csv | tail -n +2 | cut -d, -f1 | grep "^${PREFIX}-" || true); do
  echo "Logging $name out of Tailscale"
  multipass exec "$name" -- sudo tailscale logout || true
  echo "Deleting $name"
  multipass delete "$name" || true
done
multipass purge || true
rm -f artifacts/inventory/local-workers.txt
rm -f "artifacts/tmp/${PREFIX}-"*-cloud-init.yaml
