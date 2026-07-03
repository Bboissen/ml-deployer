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
done < "$INV"
