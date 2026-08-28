#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'validate-aws-dummy-publisher-policy: ERROR: %s\n' "$1" >&2
  exit 1
}

if (($# != 5)); then
  printf 'usage: %s POLICY_JSON ACCOUNT_ID REGION RESULTS_BUCKET RESOURCE_PREFIX\n' "$0" >&2
  exit 2
fi

readonly POLICY_JSON="$1"
readonly ACCOUNT_ID="$2"
readonly REGION="$3"
readonly RESULTS_BUCKET="$4"
readonly RESOURCE_PREFIX="$5"

command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "$POLICY_JSON" && ! -L "$POLICY_JSON" && -s "$POLICY_JSON" ]] ||
  fail 'policy JSON must be a non-empty regular non-symlink file'
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail 'account ID is invalid'
[[ "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || fail 'region is invalid'
[[ "$RESOURCE_PREFIX" =~ ^[a-z][a-z0-9-]{2,23}$ ]] || fail 'resource prefix is invalid'

jq -e \
  --arg account "$ACCOUNT_ID" \
  --arg region "$REGION" \
  --arg results "arn:aws:s3:::${RESULTS_BUCKET}" \
  --arg schedule "arn:aws:scheduler:${REGION}:${ACCOUNT_ID}:schedule/default/${RESOURCE_PREFIX:0:12}-run-*-stop" '
  def as_array: if type == "array" then . else [.] end;
  def statement($sid): [.PolicyDocument.Statement[] | select(.Sid == $sid)] | if length == 1 then .[0] else null end;
  def exact_statement($sid; $actions; $resources):
    statement($sid) as $s
    | $s != null
      and $s.Effect == "Allow"
      and (($s.Action | as_array | sort) == ($actions | sort))
      and (($s.Resource | as_array | sort) == ($resources | sort))
      and (($s | keys) - ["Action", "Effect", "Resource", "Sid"] | length == 0);
  (.PolicyDocument | type == "object")
  and ((.PolicyDocument | keys) - ["Statement", "Version"] | length == 0)
  and .PolicyDocument.Version == "2012-10-17"
  and ([.PolicyDocument.Statement[].Sid] | sort) == ([
    "ConditionallyCreateControlEvidenceAndReceipts",
    "ReadBoundedRunnerEvidence",
    "ReadResultsBucketLocation",
    "ReadRunnerDeadlineSchedule",
    "ReadRunnerLifecycleFacts"
  ] | sort)
  and exact_statement("ReadRunnerLifecycleFacts";
    ["ec2:DescribeInstances"]; ["*"])
  and exact_statement("ReadRunnerDeadlineSchedule";
    ["scheduler:GetSchedule"]; [$schedule])
  and exact_statement("ReadResultsBucketLocation";
    ["s3:GetBucketLocation"]; [$results])
  and exact_statement("ReadBoundedRunnerEvidence";
    ["s3:GetObject", "s3:GetObjectVersion"];
    [
      $results + "/runs/*/control-input/execution-receipt.local.json",
      $results + "/runs/*/logs/bootstrap.log",
      $results + "/runs/*/results/result-manifest.json"
    ])
  and (statement("ConditionallyCreateControlEvidenceAndReceipts") as $s
    | $s != null
      and $s.Effect == "Allow"
      and (($s.Action | as_array) == ["s3:PutObject"])
      and (($s.Resource | as_array | sort) == ([
        $results + "/control/evidence/*",
        $results + "/control/receipts/*"
      ] | sort))
      and ($s.Condition | keys) == ["StringEquals"]
      and ($s.Condition.StringEquals | keys) == ["s3:if-none-match"]
      and (($s.Condition.StringEquals["s3:if-none-match"] | as_array) == ["*"])
      and (($s | keys) - ["Action", "Condition", "Effect", "Resource", "Sid"] | length == 0))
' "$POLICY_JSON" >/dev/null || fail 'publisher policy differs from the closed five-statement contract'

printf 'validate-aws-dummy-publisher-policy: PASS\n'
