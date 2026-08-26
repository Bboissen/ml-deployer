#!/usr/bin/env bash

# Source this file to propagate one canonical .env binding to provider CLIs,
# SDKs and OpenTofu. Executing it performs the same fail-closed validation in a
# subprocess, which is useful for Make targets.

if [[ -n "${BASH_VERSION:-}" ]]; then
  _cloud_env_script_path="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  _cloud_env_script_path="${(%):-%x}"
else
  printf 'ERROR: load-cloud-env.sh requires bash or zsh.\n' >&2
  return 2 2>/dev/null || exit 2
fi

_cloud_env_main() {
  local provider="${1:-}"
  local repo_root env_file

  repo_root="$(cd "$(dirname "$_cloud_env_script_path")/.." && pwd -P)" || return 2
  env_file="${CLOUD_ENV_FILE:-${repo_root}/.env}"

  if [[ ! -f "$env_file" ]]; then
    printf 'ERROR: canonical cloud environment file is missing: %s\n' "$env_file" >&2
    return 2
  fi

  # shellcheck disable=SC1090
  source "$env_file" || return 2

  case "$provider" in
    aws)
      if [[ -z "${AWS_PROFILE:-}" || -z "${AWS_ACCOUNT_ID:-}" || -z "${AWS_REGION:-}" ]]; then
        printf 'ERROR: AWS_PROFILE, AWS_ACCOUNT_ID and AWS_REGION are required.\n' >&2
        return 2
      fi
      if ! printf '%s' "$AWS_ACCOUNT_ID" | grep -Eq '^[0-9]{12}$'; then
        printf 'ERROR: AWS_ACCOUNT_ID must contain exactly 12 digits.\n' >&2
        return 2
      fi
      if ! printf '%s' "$AWS_REGION" | grep -Eq '^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$'; then
        printf 'ERROR: AWS_REGION is not a canonical AWS region.\n' >&2
        return 2
      fi

      export AWS_PROFILE AWS_ACCOUNT_ID AWS_REGION
      export AWS_DEFAULT_REGION="$AWS_REGION"
      export TF_VAR_aws_account_id="$AWS_ACCOUNT_ID"
      export TF_VAR_aws_region="$AWS_REGION"

      printf 'cloud-env: aws account=%s region=%s profile=%s\n' \
        "$AWS_ACCOUNT_ID" "$AWS_REGION" "$AWS_PROFILE"
      ;;
    gcp)
      if [[ -z "${GCP_USER_ACCOUNT:-}" || -z "${GCP_PROJECT_ID:-}" || \
            -z "${GCP_REGION:-}" || -z "${GCP_ZONE:-}" || \
            -z "${GCP_DEPLOYER_SERVICE_ACCOUNT:-}" ]]; then
        printf 'ERROR: GCP_USER_ACCOUNT, GCP_PROJECT_ID, GCP_REGION, GCP_ZONE and GCP_DEPLOYER_SERVICE_ACCOUNT are required.\n' >&2
        return 2
      fi
      if ! printf '%s' "$GCP_PROJECT_ID" | grep -Eq '^[a-z][a-z0-9-]{4,28}[a-z0-9]$'; then
        printf 'ERROR: GCP_PROJECT_ID is not a canonical Google Cloud project ID.\n' >&2
        return 2
      fi
      if ! printf '%s' "$GCP_REGION" | grep -Eq '^[a-z]+-[a-z]+[0-9]$'; then
        printf 'ERROR: GCP_REGION is not a canonical Google Cloud region.\n' >&2
        return 2
      fi
      if ! printf '%s' "$GCP_ZONE" | grep -Eq "^${GCP_REGION}-[a-z]$"; then
        printf 'ERROR: GCP_ZONE must belong to GCP_REGION.\n' >&2
        return 2
      fi
      if [[ "$GCP_DEPLOYER_SERVICE_ACCOUNT" != *"@${GCP_PROJECT_ID}.iam.gserviceaccount.com" ]]; then
        printf 'ERROR: GCP_DEPLOYER_SERVICE_ACCOUNT must belong to GCP_PROJECT_ID.\n' >&2
        return 2
      fi

      export GCP_USER_ACCOUNT GCP_PROJECT_ID GCP_REGION GCP_ZONE
      export GCP_DEPLOYER_SERVICE_ACCOUNT
      export GOOGLE_CLOUD_PROJECT="$GCP_PROJECT_ID"
      export CLOUDSDK_CORE_PROJECT="$GCP_PROJECT_ID"
      export CLOUDSDK_COMPUTE_REGION="$GCP_REGION"
      export CLOUDSDK_COMPUTE_ZONE="$GCP_ZONE"
      export TF_VAR_project_id="$GCP_PROJECT_ID"
      export TF_VAR_region="$GCP_REGION"
      export TF_VAR_zone="$GCP_ZONE"
      export TF_VAR_deployer_principal="serviceAccount:${GCP_DEPLOYER_SERVICE_ACCOUNT}"

      printf 'cloud-env: gcp project=%s region=%s zone=%s deployer=%s\n' \
        "$GCP_PROJECT_ID" "$GCP_REGION" "$GCP_ZONE" "$GCP_DEPLOYER_SERVICE_ACCOUNT"
      ;;
    azure)
      if [[ -z "${AZURE_TENANT_ID:-}" || -z "${AZURE_SUBSCRIPTION_ID:-}" || \
            -z "${AZURE_REGION:-}" ]]; then
        printf 'ERROR: AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID and AZURE_REGION are required.\n' >&2
        return 2
      fi
      if ! printf '%s' "$AZURE_TENANT_ID" | grep -Eq \
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' || \
        ! printf '%s' "$AZURE_SUBSCRIPTION_ID" | grep -Eq \
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
        printf 'ERROR: AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID must be UUIDs.\n' >&2
        return 2
      fi
      if ! printf '%s' "$AZURE_REGION" | grep -Eq '^[a-z0-9]+$'; then
        printf 'ERROR: AZURE_REGION must be a canonical Azure location name.\n' >&2
        return 2
      fi

      export AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_REGION
      export ARM_USE_CLI=true
      export ARM_TENANT_ID="$AZURE_TENANT_ID"
      export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
      export AZURE_DEFAULTS_LOCATION="$AZURE_REGION"
      export TF_VAR_tenant_id="$AZURE_TENANT_ID"
      export TF_VAR_subscription_id="$AZURE_SUBSCRIPTION_ID"
      export TF_VAR_location="$AZURE_REGION"

      printf 'cloud-env: azure tenant=%s subscription=%s region=%s\n' \
        "$AZURE_TENANT_ID" "$AZURE_SUBSCRIPTION_ID" "$AZURE_REGION"
      ;;
    *)
      printf 'ERROR: provider must be aws, gcp or azure.\n' >&2
      return 2
      ;;
  esac
}

_cloud_env_main "$@"
_cloud_env_result=$?
unset -f _cloud_env_main
unset _cloud_env_script_path
return "$_cloud_env_result" 2>/dev/null || exit "$_cloud_env_result"
