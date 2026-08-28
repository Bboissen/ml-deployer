#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly VALIDATOR="${REPOSITORY_ROOT}/scripts/aws/validate-platform-live.sh"
readonly IAM_VALIDATOR="${REPOSITORY_ROOT}/scripts/aws/validate-platform-iam-simulation.sh"

fail() {
  printf 'test-aws-platform-live-validator: %s\n' "$1" >&2
  exit 1
}

bash -n "$VALIDATOR" || fail 'live validator has invalid shell syntax'
bash -n "$IAM_VALIDATOR" || fail 'IAM simulation validator has invalid shell syntax'

if rg -n '\] \| sort ==' "$VALIDATOR" >/dev/null; then
  fail 'live validator contains an unparenthesized jq pipeline before a boolean expression'
fi
if rg -n '^[[:space:]]*\.[[:alnum:]_.]+ \| length == .*and' "$VALIDATOR" >/dev/null; then
  fail 'live validator contains an object-losing jq length pipeline before a boolean expression'
fi

jq -ne '
  {Statement:[{Sid:"Expected",Effect:"Deny"}]} |
  (([.Statement[].Sid] | sort) == (["Expected"] | sort) and
   all(.Statement[]; .Effect == "Deny"))
' >/dev/null || fail 'bucket-policy jq regression fixture failed'

jq -ne '
  {RouteTables:[{Routes:[{DestinationCidrBlock:"0.0.0.0/0",GatewayId:"igw-1"}]}]} |
  ((.RouteTables | length) == 1 and
   ([.RouteTables[0].Routes[] | select(.GatewayId == "igw-1")] | length) == 1)
' >/dev/null || fail 'object-preserving jq length regression fixture failed'

if rg -n 'aws_read[[:space:]]+(s3api|ecr|ec2|iam|scheduler)[[:space:]]+(put|create|delete|update|modify|attach|detach|run|start|stop|terminate|set|enable|disable|associate|disassociate|register|deregister|import|copy|upload)' "$VALIDATOR" >/dev/null; then
  fail 'live validator contains a mutating AWS operation'
fi
if rg -n 'aws_read[[:space:]]+(s3api|ecr|ec2|iam|scheduler)[[:space:]]+(put|create|delete|update|modify|attach|detach|run|start|stop|terminate|set|enable|disable|associate|disassociate|register|deregister|import|copy|upload)' "$IAM_VALIDATOR" >/dev/null; then
  fail 'IAM simulation validator contains a mutating AWS operation'
fi
if rg -F 'ContextKeyType=arn' "$IAM_VALIDATOR" >/dev/null; then
  fail 'IAM simulation validator uses the unsupported arn context-entry type'
fi

for expected_read in \
  'aws_read sts get-caller-identity' \
  'aws_read s3api get-public-access-block' \
  'aws_read s3api list-object-versions' \
  'aws_read ecr describe-repositories' \
  'aws_read ecr list-tags-for-resource' \
  'aws_read ecr list-images' \
  'aws_read ec2 describe-security-groups' \
  'aws_read iam get-role' \
  'aws_read iam get-role-policy' \
  'aws_read iam get-policy-version' \
  'aws_read scheduler list-schedules'
do
  rg -F "$expected_read" "$VALIDATOR" >/dev/null || fail "missing required read-only probe: ${expected_read}"
done

if "$VALIDATOR" >/dev/null 2>&1; then
  fail 'live validator accepted missing reviewed inputs'
fi
if "$IAM_VALIDATOR" >/dev/null 2>&1; then
  fail 'IAM simulation validator accepted missing reviewed inputs'
fi

printf 'test-aws-platform-live-validator: PASS\n'
