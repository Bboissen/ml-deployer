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

while read -r ip; do
  [ -z "$ip" ] && continue
  echo "Syncing $DATA_DIR to $ip:/data/tune"
  rsync -az --delete "$DATA_DIR"/ root@"$ip":/data/tune/ &
done < "$INV"
wait
