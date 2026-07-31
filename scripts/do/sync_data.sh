#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${1:-}"
if [ -z "$DATA_DIR" ] || [ ! -d "$DATA_DIR" ]; then
  echo "Usage: $0 /path/to/compact/tune_slice" >&2
  exit 1
fi

INV="artifacts/inventory/do-worker-public-ips.txt"
if [ ! -f "$INV" ]; then
  echo "Missing $INV. Run scripts/do/render_inventory.sh after terraform apply." >&2
  exit 1
fi

pids=()
ips=()
while read -r ip; do
  [ -z "$ip" ] && continue
  echo "Syncing $DATA_DIR to $ip:/data/tune"
  # Freshly-created droplets have unknown SSH host keys; StrictHostKeyChecking would
  # reject them (rsync code 255). These are our own ephemeral fleet workers just
  # provisioned by terraform, so accept the key and don't persist it (avoids the
  # DO-IP-reuse "host identification changed" trap on the next burst).
  rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20" \
    "$DATA_DIR"/ root@"$ip":/data/tune/ &
  pids+=("$!")
  ips+=("$ip")
done < "$INV"

# Bare `wait` returns 0 even if a background rsync failed -> a partial sync would
# look like success and later reads would find no data. Wait per-pid and collect
# exit codes so any failure fails the whole sync.
fail=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    echo "ERROR: rsync to ${ips[$i]} failed" >&2
    fail=1
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "sync-data FAILED: at least one worker did not receive the data slice." >&2
  exit 1
fi
echo "sync-data OK: ${#pids[@]} worker(s) synced."
