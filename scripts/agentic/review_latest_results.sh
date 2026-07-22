#!/usr/bin/env bash
set -euo pipefail

REPORT="${1:-artifacts/live/latest_summary.md}"
mkdir -p artifacts/inbox
TS="$(date -u +%Y%m%dT%H%M%SZ)"
TASK="artifacts/inbox/review_${TS}.md"

cat > "$TASK" <<EOF
# Review request $TS

Read this live report:

- $REPORT

Use prompt:

- prompts/CODEX_SUBAGENT_RESULT_REVIEW.md

Write review to:

- artifacts/reviews/review_${TS}.md
EOF

echo "Created $TASK"

if [ -n "${CODEX_REVIEW_COMMAND:-}" ]; then
  echo "Running CODEX_REVIEW_COMMAND with $REPORT"
  # shellcheck disable=SC2086
  $CODEX_REVIEW_COMMAND "$REPORT"
fi
