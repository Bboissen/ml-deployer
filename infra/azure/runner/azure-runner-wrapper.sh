#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly CONFIG_PATH="/etc/ml-runner/request.json"
readonly RUN_SPEC_PATH="/var/lib/ml-runner/run-spec.json"
readonly RECEIPT_DIRECTORY="/var/lib/ml-runner/private-receipt"
readonly LOCAL_RECEIPT_PATH="${RECEIPT_DIRECTORY}/execution-receipt.local.json"
readonly BOOTSTRAP_LOG_PATH="/var/lib/ml-runner/bootstrap.log"
readonly BOUNDED_LOG_PATH="/var/lib/ml-runner/bootstrap.bounded.log"

AZURE_AUTHENTICATED=0
DEPLOYMENT_ID=""
RESULTS_STORAGE_ACCOUNT_NAME=""
RESULTS_CONTAINER=""
RUNTIME_IDENTITY_CLIENT_ID=""

fail() {
  printf 'azure-runner-wrapper: %s\n' "$1" >&2
  exit "${2:-64}"
}

schedule_shutdown() {
  if [[ -x /usr/sbin/shutdown ]]; then
    /usr/sbin/shutdown -h +1 >/dev/null 2>&1 || true
  fi
}
trap schedule_shutdown EXIT

upload_handoff_blob() {
  local source_path="$1"
  local blob_name="$2"

  /usr/bin/az storage blob upload \
    --auth-mode login \
    --account-name "$RESULTS_STORAGE_ACCOUNT_NAME" \
    --container-name "$RESULTS_CONTAINER" \
    --name "$blob_name" \
    --file "$source_path" \
    --if-none-match '*' \
    --overwrite false \
    --only-show-errors \
    --output none
}

finish() {
  local wrapper_exit_code=$?
  local bounded_log_ready=0
  trap - EXIT
  set +e

  if ((AZURE_AUTHENTICATED == 1)) &&
    [[ -n "$DEPLOYMENT_ID" && -n "$RESULTS_STORAGE_ACCOUNT_NAME" && -n "$RESULTS_CONTAINER" ]]; then
    if [[ -f "$LOCAL_RECEIPT_PATH" && ! -L "$LOCAL_RECEIPT_PATH" ]]; then
      if ! upload_handoff_blob \
        "$LOCAL_RECEIPT_PATH" \
        "runs/${DEPLOYMENT_ID}/control-input/execution-receipt.local.json"; then
        printf 'azure-runner-wrapper: local receipt handoff failed\n' >&2
        if ((wrapper_exit_code == 0)); then
          wrapper_exit_code=74
        fi
      fi
    elif ((wrapper_exit_code == 0)); then
      printf 'azure-runner-wrapper: successful guest exit lacked a local receipt\n' >&2
      wrapper_exit_code=74
    fi

    if [[ -x /usr/bin/tail && -x /usr/bin/chmod && -f "$BOOTSTRAP_LOG_PATH" && ! -L "$BOOTSTRAP_LOG_PATH" ]] &&
      /usr/bin/tail -c 1048576 "$BOOTSTRAP_LOG_PATH" >"$BOUNDED_LOG_PATH" &&
      /usr/bin/chmod 0600 "$BOUNDED_LOG_PATH" &&
      [[ -f "$BOUNDED_LOG_PATH" && ! -L "$BOUNDED_LOG_PATH" ]]; then
      bounded_log_ready=1
    else
      printf 'azure-runner-wrapper: bounded bootstrap log creation failed\n' >&2
      if ((wrapper_exit_code == 0)); then
        wrapper_exit_code=74
      fi
    fi
    if ((bounded_log_ready == 1)) && ! upload_handoff_blob \
      "$BOUNDED_LOG_PATH" \
      "runs/${DEPLOYMENT_ID}/logs/bootstrap.log"; then
      printf 'azure-runner-wrapper: bounded bootstrap log handoff failed\n' >&2
      if ((wrapper_exit_code == 0)); then
        wrapper_exit_code=74
      fi
    fi
  fi

  schedule_shutdown
  exit "$wrapper_exit_code"
}

# Install shutdown/finalization and local logging before prepared-image and
# request checks so early bootstrap failures remain observable when possible.
trap finish EXIT
if [[ -d /var/lib/ml-runner && ! -L /var/lib/ml-runner && ! -L "$BOOTSTRAP_LOG_PATH" ]]; then
  : >>"$BOOTSTRAP_LOG_PATH"
  if [[ -x /usr/bin/chmod ]]; then
    /usr/bin/chmod 0600 "$BOOTSTRAP_LOG_PATH"
  fi
  exec >>"$BOOTSTRAP_LOG_PATH" 2>&1
else
  fail "bootstrap log directory is unavailable" 70
fi

read_config() {
  /usr/bin/jq -er --arg key "$1" '.[$key] | select(type == "string" or type == "number")' "$CONFIG_PATH"
}

# Authenticate early when the minimum prepared-image/config surface exists so
# later tool failures can still publish a bounded diagnostic log.
for early_path in /usr/bin/az /usr/bin/jq; do
  [[ -x "$early_path" ]] || fail "required prepared-image executable is missing: ${early_path}" 70
done
[[ -f "$CONFIG_PATH" && ! -L "$CONFIG_PATH" ]] || fail "request binding is missing" 70
[[ -d "$RECEIPT_DIRECTORY" && ! -L "$RECEIPT_DIRECTORY" ]] || fail "private receipt directory is missing" 70
[[ ! -L "$BOOTSTRAP_LOG_PATH" && ! -L "$BOUNDED_LOG_PATH" ]] || fail "bootstrap log path may not be a symbolic link" 70

DEPLOYMENT_ID="$(read_config deployment_id)"
readonly DEPLOYMENT_ID
readonly RESULTS_URI="$(read_config results_uri)"
RUNTIME_IDENTITY_CLIENT_ID="$(read_config runtime_identity_client_id)"
readonly RUNTIME_IDENTITY_CLIENT_ID

[[ "$RESULTS_URI" =~ ^https://([a-z0-9]{3,24})\.blob\.core\.windows\.net/(results)/runs/([^/]+)/results/$ ]] ||
  fail "results URI is not the deployment-specific Azure results prefix"
RESULTS_STORAGE_ACCOUNT_NAME="${BASH_REMATCH[1]}"
RESULTS_CONTAINER="${BASH_REMATCH[2]}"
[[ "${BASH_REMATCH[3]}" == "$DEPLOYMENT_ID" ]] ||
  fail "results URI is bound to a different deployment"

/usr/bin/az login \
  --identity \
  --client-id "$RUNTIME_IDENTITY_CLIENT_ID" \
  --allow-no-subscriptions \
  --output none
AZURE_AUTHENTICATED=1

for required_path in \
  /usr/bin/chmod \
  /usr/bin/cut \
  /usr/bin/docker \
  /usr/bin/env \
  /usr/bin/sha256sum \
  /usr/bin/tail \
  /opt/ml/bin/guest-runner.sh
do
  [[ -x "$required_path" ]] || fail "required prepared-image executable is missing: ${required_path}" 70
done
readonly OCI_REPOSITORY="$(read_config oci_repository)"
readonly OCI_DIGEST="$(read_config oci_digest)"
readonly RUN_SPEC_URI="$(read_config run_spec_uri)"
readonly RUN_SPEC_SHA256="$(read_config run_spec_sha256)"
readonly RUN_SPEC_OBJECT_VERSION="$(read_config run_spec_object_version)"
readonly DATA_URI="$(read_config data_uri)"
readonly MAXIMUM_RUNTIME_MINUTES="$(read_config maximum_runtime_minutes)"
readonly ACR_NAME="$(read_config acr_name)"

[[ "$RUN_SPEC_URI" =~ ^https://([a-z0-9]{3,24})\.blob\.core\.windows\.net/([^/]+)/(.+)$ ]] ||
  fail "run-spec URI is not an Azure Blob object URI"
readonly STORAGE_ACCOUNT_NAME="${BASH_REMATCH[1]}"
readonly RUN_SPEC_CONTAINER="${BASH_REMATCH[2]}"
readonly RUN_SPEC_BLOB="${BASH_REMATCH[3]}"

/usr/bin/az acr login --name "$ACR_NAME" --output none
/usr/bin/az storage blob download \
  --auth-mode login \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name "$RUN_SPEC_CONTAINER" \
  --name "$RUN_SPEC_BLOB" \
  --version-id "$RUN_SPEC_OBJECT_VERSION" \
  --file "$RUN_SPEC_PATH" \
  --overwrite false \
  --output none

[[ "$(/usr/bin/sha256sum "$RUN_SPEC_PATH" | /usr/bin/cut -d' ' -f1)" == "$RUN_SPEC_SHA256" ]] ||
  fail "downloaded run-spec SHA-256 does not match the reviewed request" 65

set +e
/usr/bin/env \
  ML_DEPLOYMENT_ID="$DEPLOYMENT_ID" \
  ML_OCI_REPOSITORY="$OCI_REPOSITORY" \
  ML_OCI_DIGEST="$OCI_DIGEST" \
  ML_RUN_SPEC_URI="$RUN_SPEC_URI" \
  ML_RUN_SPEC_SHA256="$RUN_SPEC_SHA256" \
  ML_RUN_SPEC_OBJECT_VERSION="$RUN_SPEC_OBJECT_VERSION" \
  ML_DATA_URI="$DATA_URI" \
  ML_RESULTS_URI="$RESULTS_URI" \
  ML_CLOUD_PROVIDER="azure" \
  ML_WORKLOAD_IDENTITY_CLIENT_ID="$RUNTIME_IDENTITY_CLIENT_ID" \
  ML_MAX_RUNTIME_MINUTES="$MAXIMUM_RUNTIME_MINUTES" \
  ML_CONTAINER_RUNTIME_PATH="/usr/bin/docker" \
  ML_RECEIPT_OUTPUT_DIRECTORY="$RECEIPT_DIRECTORY" \
  /opt/ml/bin/guest-runner.sh
guest_exit_code=$?
set -e

exit "$guest_exit_code"
