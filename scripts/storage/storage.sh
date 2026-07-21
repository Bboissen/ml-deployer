#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STORAGE_DIR="$ROOT_DIR/terraform/digitalocean-storage"
WORKER_DIR="$ROOT_DIR/terraform/digitalocean-workers"
TF_BIN="${TF:-terraform}"
PHASE1_SENTINEL_UUID="00000000-0000-4000-8000-000000000000"
PHASE1_SENTINEL_NAME="phase1-plan-sentinel"
PHASE1_SENTINEL_CIDR="10.255.240.0/20"

die() {
  printf 'storage: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_env() {
  [[ -n "${!1:-}" ]] || die "required environment variable is unset or empty: $1"
}

guard_live_vpc() {
  require_env TF_VAR_vpc_uuid
  require_env TF_VAR_vpc_name
  require_env TF_VAR_vpc_cidr
  [[ "$TF_VAR_vpc_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] ||
    die "TF_VAR_vpc_uuid must be a syntactically valid UUID"
  [[ "$TF_VAR_vpc_uuid" != "$PHASE1_SENTINEL_UUID" ]] ||
    die "Phase 1 sentinel VPC UUID is forbidden for apply and live workers"
  [[ "$TF_VAR_vpc_name" != "$PHASE1_SENTINEL_NAME" ]] ||
    die "Phase 1 sentinel VPC name is forbidden for apply and live workers"
  [[ "$TF_VAR_vpc_cidr" != "$PHASE1_SENTINEL_CIDR" ]] ||
    die "Phase 1 sentinel VPC CIDR is forbidden for apply and live workers"
  printf 'Live VPC guard accepted: %s (%s, %s).\n' "$TF_VAR_vpc_name" "$TF_VAR_vpc_uuid" "$TF_VAR_vpc_cidr"
}

tf() {
  "$TF_BIN" "$@"
}

resource_block() {
  local resource_type="$1"
  local resource_name="$2"

  awk -v wanted_type="$resource_type" -v wanted_name="$resource_name" '
    $0 ~ "^[[:space:]]*resource[[:space:]]+\\\"" wanted_type "\\\"[[:space:]]+\\\"" wanted_name "\\\"[[:space:]]*\\{" {
      active = 1
    }
    active {
      print
      line = $0
      opens += gsub(/\{/, "", line)
      line = $0
      closes += gsub(/\}/, "", line)
      if (opens > 0 && opens == closes) {
        exit
      }
    }
  ' "$STORAGE_DIR/main.tf"
}

assert_source_policy() {
  local address resource_type resource_name block

  [[ "$(grep -Ec '^[[:space:]]*resource "digitalocean_vpc" ' "$STORAGE_DIR/main.tf")" == "1" ]] ||
    die "source policy requires exactly one digitalocean_vpc resource"
  [[ "$(grep -Ec '^[[:space:]]*resource "digitalocean_spaces_bucket" ' "$STORAGE_DIR/main.tf")" == "2" ]] ||
    die "source policy requires exactly two digitalocean_spaces_bucket resources"

  for address in digitalocean_vpc.demo digitalocean_spaces_bucket.state digitalocean_spaces_bucket.bronze; do
    resource_type="${address%%.*}"
    resource_name="${address#*.}"
    block="$(resource_block "$resource_type" "$resource_name")"
    [[ -n "$block" ]] || die "source policy could not find $address"
    grep -Eq '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$' <<<"$block" ||
      die "source policy requires prevent_destroy = true on $address"
  done
}

init_storage() {
  tf -chdir="$STORAGE_DIR" init -backend=false -input=false
}

validate_backend_example() (
  local temp_root
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/ray-storage-backend.XXXXXX")"
  trap 'rm -rf "$temp_root"' EXIT

  cp "$STORAGE_DIR/backend.tf.example" "$temp_root/backend.tf"
  tf -chdir="$temp_root" init -backend=false -input=false >/dev/null
  tf -chdir="$temp_root" validate >/dev/null
)

validate_storage() {
  tf -chdir="$STORAGE_DIR" fmt -check
  tf -chdir="$STORAGE_DIR" validate
  validate_backend_example
  assert_source_policy
  printf '%s\n' "Storage configuration and inactive backend example are valid."
}

assert_storage_plan() {
  local plan_json="$1"

  jq -e '
    def change($address):
      .resource_changes[] | select(.address == $address) | .change;
    def empty_or_absent($value):
      ($value == null) or (($value | length) == 0);

    (.resource_changes | length) == 3 and
    ([.resource_changes[].address] | sort) == ([
      "digitalocean_spaces_bucket.bronze",
      "digitalocean_spaces_bucket.state",
      "digitalocean_vpc.demo"
    ] | sort) and
    (all(.resource_changes[]; .change.actions == ["create"])) and

    (change("digitalocean_vpc.demo").after.region == "ams3") and
    (change("digitalocean_vpc.demo").after.name == $vpc_name) and

    (change("digitalocean_spaces_bucket.state").after.region == "ams3") and
    (change("digitalocean_spaces_bucket.state").after.name == $state_bucket) and
    (change("digitalocean_spaces_bucket.state").after.name != change("digitalocean_spaces_bucket.bronze").after.name) and
    (change("digitalocean_spaces_bucket.state").after.acl == "private") and
    (change("digitalocean_spaces_bucket.state").after.force_destroy == false) and
    (change("digitalocean_spaces_bucket.state").after.versioning[0].enabled == true) and
    empty_or_absent(change("digitalocean_spaces_bucket.state").after.lifecycle_rule) and

    (change("digitalocean_spaces_bucket.bronze").after.region == "ams3") and
    (change("digitalocean_spaces_bucket.bronze").after.name == $bronze_bucket) and
    (change("digitalocean_spaces_bucket.bronze").after.acl == "private") and
    (change("digitalocean_spaces_bucket.bronze").after.force_destroy == false) and
    (change("digitalocean_spaces_bucket.bronze").after.versioning[0].enabled == true) and
    (change("digitalocean_spaces_bucket.bronze").after.lifecycle_rule | length == 1) and
    (change("digitalocean_spaces_bucket.bronze").after.lifecycle_rule[0].id == "expire-smoke-test-packs") and
    (change("digitalocean_spaces_bucket.bronze").after.lifecycle_rule[0].prefix == "smoke/") and
    (change("digitalocean_spaces_bucket.bronze").after.lifecycle_rule[0].enabled == true) and
    (change("digitalocean_spaces_bucket.bronze").after.lifecycle_rule[0].abort_incomplete_multipart_upload_days == 7) and
    (change("digitalocean_spaces_bucket.bronze").after.lifecycle_rule[0].expiration[0].days == 7) and
    (change("digitalocean_spaces_bucket.bronze").after.lifecycle_rule[0].noncurrent_version_expiration[0].days == 90)
  ' \
    --arg state_bucket "$TF_VAR_state_bucket_name" \
    --arg bronze_bucket "$TF_VAR_bronze_bucket_name" \
    --arg vpc_name "$TF_VAR_vpc_name" \
    "$plan_json" >/dev/null || die "storage plan failed semantic policy"
}

plan_storage() (
  local temp_root plan_file plan_json

  require_command jq
  require_env TF_VAR_state_bucket_name
  require_env TF_VAR_bronze_bucket_name
  require_env TF_VAR_vpc_name
  [[ "$TF_VAR_state_bucket_name" != "$TF_VAR_bronze_bucket_name" ]] ||
    die "state and Bronze bucket names must differ"
  require_env DIGITALOCEAN_TOKEN
  require_env SPACES_ACCESS_KEY_ID
  require_env SPACES_SECRET_ACCESS_KEY

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/ray-storage-plan.XXXXXX")"
  trap 'rm -rf "$temp_root"' EXIT
  plan_file="$temp_root/storage.tfplan"
  plan_json="$temp_root/storage-plan.json"

  tf -chdir="$STORAGE_DIR" plan \
    -input=false \
    -lock=false \
    -refresh=false \
    -out="$plan_file" >/dev/null
  tf -chdir="$STORAGE_DIR" show -json "$plan_file" >"$plan_json"

  assert_storage_plan "$plan_json"
  assert_source_policy
  printf 'Storage plan verified: 3 creates, VPC=%s, state bucket=%s, Bronze bucket=%s, region=ams3.\n' \
    "$TF_VAR_vpc_name" "$TF_VAR_state_bucket_name" "$TF_VAR_bronze_bucket_name"
)

assert_worker_plan() {
  local plan_json="$1"
  local expected_count="$2"
  local expected_vpc_uuid="$3"
  local expected_vpc_cidr="$4"
  local expected_vpc_resolver_ip="$5"

  jq -e '
    ([.resource_changes[].change.actions[]] | index("update") | not) and
    ([.resource_changes[].change.actions[]] | index("delete") | not) and
    ([.resource_changes[] | select(.type == "digitalocean_droplet")] | length == $expected_count) and
    (all(.resource_changes[] | select(.type == "digitalocean_droplet");
      .change.after.vpc_uuid == $expected_vpc_uuid)) and
    (.planned_values.outputs.selected_vpc_cidr.value == $expected_vpc_cidr) and
    (.planned_values.outputs.selected_vpc_resolver_ip.value == $expected_vpc_resolver_ip)
  ' \
    --argjson expected_count "$expected_count" \
    --arg expected_vpc_uuid "$expected_vpc_uuid" \
    --arg expected_vpc_cidr "$expected_vpc_cidr" \
    --arg expected_vpc_resolver_ip "$expected_vpc_resolver_ip" \
    "$plan_json" >/dev/null || die "worker plan failed VPC/action policy"
}

plan_workers() (
  local worker_count="${1:-1}"
  local allow_phase1_plan_sentinel=false
  local expected_vpc_resolver_ip
  local temp_root plan_file plan_json

  require_command jq
  require_env TF_VAR_vpc_uuid
  require_env TF_VAR_vpc_name
  require_env TF_VAR_vpc_cidr
  expected_vpc_resolver_ip="$(python3 -c 'import ipaddress, os; print(ipaddress.ip_network(os.environ["TF_VAR_vpc_cidr"], strict=False).broadcast_address - 1)' 2>/dev/null)" ||
    die "TF_VAR_vpc_cidr must be a valid IPv4 CIDR"
  [[ "$worker_count" =~ ^[0-9]+$ ]] || die "worker count must be a non-negative integer"
  if [[ "$TF_VAR_vpc_uuid" == "$PHASE1_SENTINEL_UUID" && "$TF_VAR_vpc_name" == "$PHASE1_SENTINEL_NAME" && "$TF_VAR_vpc_cidr" == "$PHASE1_SENTINEL_CIDR" ]]; then
    allow_phase1_plan_sentinel=true
  fi

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/ray-worker-plan.XXXXXX")"
  trap 'rm -rf "$temp_root"' EXIT
  plan_file="$temp_root/workers.tfplan"
  plan_json="$temp_root/workers-plan.json"

  tf -chdir="$WORKER_DIR" plan \
    -input=false \
    -lock=false \
    -refresh=false \
    -var="worker_count=$worker_count" \
    -var="allow_phase1_plan_sentinel=$allow_phase1_plan_sentinel" \
    -out="$plan_file" >/dev/null
  tf -chdir="$WORKER_DIR" show -json "$plan_file" >"$plan_json"

  assert_worker_plan "$plan_json" "$worker_count" "$TF_VAR_vpc_uuid" "$TF_VAR_vpc_cidr" "$expected_vpc_resolver_ip"
  printf 'Worker plan verified: count=%s, VPC=%s (%s, %s), resolver=%s, no update/delete/replace actions.\n' \
    "$worker_count" "$TF_VAR_vpc_name" "$TF_VAR_vpc_uuid" "$TF_VAR_vpc_cidr" "$expected_vpc_resolver_ip"
)

usage() {
  cat <<'EOF'
Usage: storage.sh <init|validate|plan|worker-plan|guard-live-vpc> [worker-count]

All actions are non-creating. Backend activation, apply, migration, and destroy
are intentionally absent and require separate human-gated procedures.
EOF
}

case "${1:-}" in
  init)
    require_command "$TF_BIN"
    init_storage
    ;;
  validate)
    require_command "$TF_BIN"
    validate_storage
    ;;
  plan)
    require_command "$TF_BIN"
    plan_storage
    ;;
  worker-plan)
    require_command "$TF_BIN"
    plan_workers "${2:-1}"
    ;;
  guard-live-vpc)
    guard_live_vpc
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
