#!/usr/bin/env bash
set -euo pipefail

if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

if [ -z "${RAY_HEAD_TS_IP:-}" ]; then
  if command -v tailscale >/dev/null; then
    RAY_HEAD_TS_IP="$(tailscale ip -4 | head -n1)"
  else
    echo "RAY_HEAD_TS_IP is not set and tailscale command is unavailable" >&2
    exit 1
  fi
fi

RAY_HEAD_PORT="${RAY_HEAD_PORT:-6379}"
RAY_DASHBOARD_PORT="${RAY_DASHBOARD_PORT:-8265}"
RAY_CLIENT_PORT="${RAY_CLIENT_PORT:-10001}"
RAY_MIN_WORKER_PORT="${RAY_MIN_WORKER_PORT:-10002}"
RAY_MAX_WORKER_PORT="${RAY_MAX_WORKER_PORT:-10100}"
RAY_OBJECT_STORE_MEMORY="${RAY_OBJECT_STORE_MEMORY:-268435456}"
RAY_HEAD_CPUS="${RAY_HEAD_CPUS:-0}"

# shellcheck disable=SC1091
source .venv/bin/activate
ray_args=(
  --head
  --node-ip-address="$RAY_HEAD_TS_IP"
  --port="$RAY_HEAD_PORT"
  --ray-client-server-port="$RAY_CLIENT_PORT"
  --dashboard-host="$RAY_HEAD_TS_IP"
  --dashboard-port="$RAY_DASHBOARD_PORT"
  --min-worker-port="$RAY_MIN_WORKER_PORT"
  --max-worker-port="$RAY_MAX_WORKER_PORT"
  --node-manager-port=11001
  --object-manager-port=11002
  --runtime-env-agent-port=11003
  --dashboard-agent-listen-port=11004
  --metrics-export-port=11005
  --object-store-memory="$RAY_OBJECT_STORE_MEMORY"
  --num-cpus="$RAY_HEAD_CPUS"
  --disable-usage-stats
  --block
)
exec ray start "${ray_args[@]}"
