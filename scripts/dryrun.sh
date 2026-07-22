#!/usr/bin/env bash
set -euo pipefail

mkdir -p artifacts
cat <<EOF
Dry run context
===============
Repo: $(pwd)
Date UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Tailscale head IP: ${RAY_HEAD_TS_IP:-unset}
DO region: ${TF_VAR_region:-unset}
DO size: ${TF_VAR_size:-unset}
DO worker count: ${TF_VAR_worker_count:-1}
Local VM worker count: ${WORKER_COUNT:-unset}
Ray head CPUs: ${RAY_HEAD_CPUS:-0}

Safe commands:
- make do-plan DO_WORKER_COUNT=1
- make local-lab-up WORKER_COUNT=1

Billable command:
- make do-up DO_WORKER_COUNT=N
EOF
