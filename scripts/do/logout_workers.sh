#!/usr/bin/env bash
set -euo pipefail

if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

prefix="${TF_VAR_cluster_name:-spotify-ray}-worker-"

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale CLI not found; skipping worker logout" >&2
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

tailscale status --json | python3 -c '
import json
import sys

prefix = sys.argv[1]
data = json.load(sys.stdin)
for peer in data.get("Peer", {}).values():
    host = peer.get("HostName") or ""
    ips = peer.get("TailscaleIPs") or []
    if host.startswith(prefix) and ips and peer.get("Online"):
        print(host, ips[0])
' "$prefix" > "$tmp"

if [ ! -s "$tmp" ]; then
  echo "No online Tailscale workers found for prefix $prefix"
  exit 0
fi

while read -r host ip; do
  [ -z "$ip" ] && continue
  echo "Logging $host ($ip) out of Tailscale"
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new \
    "root@$ip" \
    'sudo tailscale logout || true' || true
done < "$tmp"
