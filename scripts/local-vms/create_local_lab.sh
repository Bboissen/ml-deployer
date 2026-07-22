#!/usr/bin/env bash
set -euo pipefail

if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

WORKER_COUNT="${1:-${WORKER_COUNT:-3}}"
PREFIX="${LOCAL_VM_PREFIX:-ray-lab-worker}"
CPUS="${LOCAL_VM_CPUS:-1}"
MEMORY="${LOCAL_VM_MEMORY:-2G}"
DISK="${LOCAL_VM_DISK:-12G}"

if ! command -v multipass >/dev/null; then
  echo "multipass is required for local VM lab. Install with: sudo snap install multipass" >&2
  exit 1
fi

if [ -z "${TS_AUTH_KEY:-}" ]; then
  echo "TS_AUTH_KEY must be set for local VM lab workers" >&2
  exit 1
fi

if [ -z "${RAY_HEAD_TS_IP:-}" ]; then
  RAY_HEAD_TS_IP="$(tailscale ip -4 | head -n1)"
fi

mkdir -p artifacts/inventory artifacts/tmp

for i in $(seq 1 "$WORKER_COUNT"); do
  name="${PREFIX}-${i}"
  echo "Launching $name"
  cloud_init="artifacts/tmp/${name}-cloud-init.yaml"
  sed \
    -e "s|__TS_AUTH_KEY__|${TS_AUTH_KEY}|g" \
    -e "s|__RAY_HEAD_TS_IP__|${RAY_HEAD_TS_IP}|g" \
    -e "s|__WORKER_HOSTNAME__|${name}|g" \
    cloud-init/local-worker.yaml.tftpl > "$cloud_init"

  if multipass info "$name" >/dev/null 2>&1; then
    echo "$name already exists, skipping launch"
  else
    multipass launch 24.04 --name "$name" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK" --cloud-init "$cloud_init"
  fi

done

: > artifacts/inventory/local-workers.txt
for i in $(seq 1 "$WORKER_COUNT"); do
  name="${PREFIX}-${i}"
  echo "$name" >> artifacts/inventory/local-workers.txt
done

echo "Local lab workers requested. Wait 1-3 minutes, then run: make ray-status EXPECTED_WORKERS=$WORKER_COUNT"
