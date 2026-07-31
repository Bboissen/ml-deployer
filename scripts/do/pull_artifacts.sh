#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-artifacts/pulled}"
INV="artifacts/inventory/do-worker-public-ips.txt"
mkdir -p "$OUT_DIR"

if [ ! -f "$INV" ]; then
  echo "Missing $INV. Nothing to pull." >&2
  exit 1
fi

idx=0
while read -r ip; do
  [ -z "$ip" ] && continue
  idx=$((idx + 1))
  mkdir -p "$OUT_DIR/worker-$idx"
  echo "Pulling artifacts from $ip"
  rsync -az root@"$ip":/artifacts/ "$OUT_DIR/worker-$idx"/ || true
  # OOF quantile predictions from finalist runs (save_predictions_dir writes them
  # under /data/tune/oof on whichever worker ran the trial). NB /data/tune is
  # cleaned by sync-data --delete, so pull BEFORE any re-sync.
  rsync -az \
    -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20" \
    root@"$ip":/data/tune/oof/ "$OUT_DIR/worker-$idx/oof/" 2>/dev/null || true
done < "$INV"
