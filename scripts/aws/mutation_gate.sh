#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-unknown}"
printf 'aws-mutation-gate: REFUSED action=%s\n' "$action" >&2
printf '%s\n' 'Goals 01-02 are code-only. No AWS mutation, apply, or destroy implementation is authorized.' >&2
exit 1
