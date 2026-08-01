#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='example-project'
MODE="${1:---json}"
command -v gcloud >/dev/null 2>&1 || { printf '%s\n' 'gcp-audit: gcloud is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'gcp-audit: jq is required' >&2; exit 1; }

instances="$(gcloud compute instances list --project "$PROJECT" --filter='labels.managed_by=opentofu AND labels.role=training' --format=json)"
disks="$(gcloud compute disks list --project "$PROJECT" --filter='labels.managed_by=opentofu AND labels.role=training' --format=json)"
addresses="$(gcloud compute addresses list --project "$PROJECT" --format=json)"
snapshots="$(gcloud compute snapshots list --project "$PROJECT" --format=json)"
images="$(gcloud compute images list --project "$PROJECT" --no-standard-images --format=json)"
forwarding_rules="$(gcloud compute forwarding-rules list --project "$PROJECT" --format=json)"
routers="$(gcloud compute routers list --project "$PROJECT" --format=json)"
clusters="$(gcloud container clusters list --project "$PROJECT" --format=json 2>/dev/null || printf '[]')"
audit="$(jq -n --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson instances "$instances" --argjson disks "$disks" --argjson addresses "$addresses" --argjson snapshots "$snapshots" --argjson images "$images" --argjson forwarding_rules "$forwarding_rules" --argjson routers "$routers" --argjson clusters "$clusters" '{checked_at:$checked_at,project_id:"example-project",training_instances:$instances,training_disks:$disks,reserved_addresses:$addresses,snapshots:$snapshots,custom_images:$images,forwarding_rules:$forwarding_rules,routers:$routers,gke_clusters:$clusters}')"

mkdir -p artifacts/audits
umask 077
output="artifacts/audits/gcp-resources-$(date -u +%Y%m%dT%H%M%SZ).json"
printf '%s\n' "$audit" >"$output"
chmod 0600 "$output"
printf '%s\n' "$audit"

if [[ "$MODE" == --verify-smoke ]]; then
  jq -e '.training_instances == [] and .training_disks == [] and .reserved_addresses == [] and .snapshots == [] and .custom_images == [] and .forwarding_rules == [] and .routers == [] and .gke_clusters == []' <<<"$audit" >/dev/null || {
    printf '%s\n' 'gcp-audit: disposable or reserved resources remain' >&2
    exit 1
  }
  [[ -n "${GCP_RUN_ID:-}" && -n "${GCP_ARTIFACT_BUCKET:-}" ]] || { printf '%s\n' 'gcp-audit: GCP_RUN_ID and GCP_ARTIFACT_BUCKET are required for smoke verification' >&2; exit 1; }
  gcloud storage ls "gs://$GCP_ARTIFACT_BUCKET/artifacts/runs/$GCP_RUN_ID/COMPLETED.json" >/dev/null
fi
