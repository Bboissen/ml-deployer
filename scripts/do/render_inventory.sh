#!/usr/bin/env bash
set -euo pipefail

TF_DIR="terraform/digitalocean-workers"
TF="${TF:-terraform}"
mkdir -p artifacts/inventory

"$TF" -chdir="$TF_DIR" output -json > artifacts/inventory/do-terraform-outputs.json
"$TF" -chdir="$TF_DIR" output -json worker_public_ips | jq -r '.[]' > artifacts/inventory/do-worker-public-ips.txt
"$TF" -chdir="$TF_DIR" output -json worker_names | jq -r '.[]' > artifacts/inventory/do-worker-names.txt

echo "Wrote artifacts/inventory/do-worker-public-ips.txt"
