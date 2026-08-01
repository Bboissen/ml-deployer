#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_PROJECT='example-project'
EXPECTED_REGION='us-central1'
EXPECTED_ZONE='us-central1-a'
REQUIRED_APIS=(
  serviceusage.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com
  iamcredentials.googleapis.com compute.googleapis.com storage.googleapis.com
  iap.googleapis.com oslogin.googleapis.com logging.googleapis.com monitoring.googleapis.com
)
JSON_MODE=false
OUTPUT=''

while (($#)); do
  case "$1" in
    --json) JSON_MODE=true ;;
    --output) shift; OUTPUT="${1:?--output requires a path}" ;;
    *) printf 'account-check: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

for command_name in gcloud tofu jq python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'account-check: required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)"
active_project="$(gcloud config get-value project 2>/dev/null)"
region="$(gcloud config get-value compute/region 2>/dev/null)"
zone="$(gcloud config get-value compute/zone 2>/dev/null)"
project_json="$(gcloud projects describe "$EXPECTED_PROJECT" --format=json 2>/dev/null)"
billing_json="$(gcloud billing projects describe "$EXPECTED_PROJECT" --format=json 2>/dev/null)"
enabled_apis="$(gcloud services list --enabled --project "$EXPECTED_PROJECT" --format='value(config.name)' 2>/dev/null)"
quota_json="$(gcloud compute regions describe "$EXPECTED_REGION" --project "$EXPECTED_PROJECT" --format=json 2>/dev/null || printf '{}')"
bootstrap_roles="$(gcloud projects get-iam-policy "$EXPECTED_PROJECT" --flatten='bindings[].members' --filter="bindings.members:user:$active_account" --format='value(bindings.role)' 2>/dev/null)"

[[ -n "$active_account" ]] || { printf '%s\n' 'account-check: no active gcloud account' >&2; exit 1; }
[[ "$active_project" == "$EXPECTED_PROJECT" ]] || { printf 'account-check: active project is %s, expected %s\n' "$active_project" "$EXPECTED_PROJECT" >&2; exit 1; }
[[ "$region" == "$EXPECTED_REGION" ]] || { printf 'account-check: region is %s, expected %s\n' "$region" "$EXPECTED_REGION" >&2; exit 1; }
[[ "$zone" == "$EXPECTED_ZONE" ]] || { printf 'account-check: zone is %s, expected %s\n' "$zone" "$EXPECTED_ZONE" >&2; exit 1; }
[[ "$(jq -r '.lifecycleState' <<<"$project_json")" == 'ACTIVE' ]] || { printf '%s\n' 'account-check: project is not ACTIVE' >&2; exit 1; }
[[ "$(jq -r '.billingEnabled' <<<"$billing_json")" == 'true' ]] || { printf '%s\n' 'account-check: billing is not enabled' >&2; exit 1; }

missing_apis=()
for api in "${REQUIRED_APIS[@]}"; do
  grep -Fxq "$api" <<<"$enabled_apis" || missing_apis+=("$api")
done

bootstrap_permissions_ok=false
if grep -Fxq 'roles/owner' <<<"$bootstrap_roles"; then
  bootstrap_permissions_ok=true
elif grep -Fxq 'roles/resourcemanager.projectIamAdmin' <<<"$bootstrap_roles" && grep -Fxq 'roles/iam.serviceAccountAdmin' <<<"$bootstrap_roles" && grep -Fxq 'roles/storage.admin' <<<"$bootstrap_roles"; then
  bootstrap_permissions_ok=true
fi

gcloud auth application-default print-access-token >/dev/null 2>&1 || {
  printf '%s\n' 'account-check: ADC cannot obtain a token' >&2
  exit 1
}

clock_synchronized=unknown
# systemd documents presence of this empty marker as proof of synchronization.
if [[ -e /run/systemd/timesync/synchronized ]]; then
  clock_synchronized=true
elif command -v timedatectl >/dev/null 2>&1; then
  clock_synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf unknown)"
fi

audit="$(jq -n \
  --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg active_account "$active_account" \
  --arg project_id "$active_project" \
  --arg project_number "$(jq -r '.projectNumber' <<<"$project_json")" \
  --arg lifecycle_state "$(jq -r '.lifecycleState' <<<"$project_json")" \
  --arg region "$region" --arg zone "$zone" \
  --arg clock_synchronized "$clock_synchronized" \
  --argjson bootstrap_permissions_ok "$bootstrap_permissions_ok" \
  --argjson bootstrap_roles "$(printf '%s\n' "$bootstrap_roles" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson quotas "$(jq '[.quotas[]? | select(.metric == "CPUS" or .metric == "IN_USE_ADDRESSES") | {metric, limit, usage}]' <<<"$quota_json")" \
  --argjson enabled_apis "$(printf '%s\n' "$enabled_apis" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson missing_apis "$(printf '%s\n' "${missing_apis[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  '{checked_at:$checked_at,active_account:$active_account,project_id:$project_id,project_number:$project_number,lifecycle_state:$lifecycle_state,billing_enabled:true,region:$region,zone:$zone,adc_token_obtainable:true,clock_synchronized:$clock_synchronized,bootstrap_permissions_ok:$bootstrap_permissions_ok,bootstrap_roles:$bootstrap_roles,enabled_required_apis:$enabled_apis,missing_required_apis:$missing_apis,regional_quotas:$quotas}')"

if [[ "$JSON_MODE" == true ]]; then
  [[ -n "$OUTPUT" ]] || OUTPUT="artifacts/audits/gcp-account-$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$OUTPUT")"
  umask 077
  printf '%s\n' "$audit" >"$OUTPUT"
  chmod 0600 "$OUTPUT"
  printf '%s\n' "$audit"
else
  jq -r '"account=\(.active_account) project=\(.project_id) number=\(.project_number) state=\(.lifecycle_state) billing=\(.billing_enabled) region=\(.region) zone=\(.zone)", "bootstrap_permissions_ok=\(.bootstrap_permissions_ok)", "missing_apis=\(.missing_required_apis | join(","))", "clock_synchronized=\(.clock_synchronized)"' <<<"$audit"
fi

((${#missing_apis[@]} == 0)) || exit 1
[[ "$bootstrap_permissions_ok" == true ]] || exit 1
[[ "$clock_synchronized" == true ]] || exit 1
