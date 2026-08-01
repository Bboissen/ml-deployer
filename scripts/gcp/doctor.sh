#!/usr/bin/env bash
set -Eeuo pipefail

missing=0
for command_name in gcloud tofu git make python3 jq; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf 'ok: %s -> %s\n' "$command_name" "$(command -v "$command_name")"
  else
    printf 'missing: %s\n' "$command_name" >&2
    missing=1
  fi
done

if command -v shellcheck >/dev/null 2>&1 || [[ -x .venv/bin/shellcheck ]]; then
  printf '%s\n' 'ok: shellcheck'
else
  printf '%s\n' 'missing: shellcheck' >&2
  missing=1
fi

python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' || {
  printf '%s\n' 'doctor: Python 3.12 or newer is required' >&2
  missing=1
}

if command -v ruff >/dev/null 2>&1 || python3 -m ruff --version >/dev/null 2>&1 || .venv/bin/python -m ruff --version >/dev/null 2>&1; then
  printf '%s\n' 'ok: ruff'
else
  printf '%s\n' 'missing: ruff' >&2
  missing=1
fi

if command -v pytest >/dev/null 2>&1 || python3 -m pytest --version >/dev/null 2>&1 || .venv/bin/python -m pytest --version >/dev/null 2>&1; then
  printf '%s\n' 'ok: pytest'
else
  printf '%s\n' 'missing: pytest' >&2
  missing=1
fi

((missing == 0)) || {
  printf '%s\n' 'doctor: install the missing local tools; no cloud changes were attempted.' >&2
  exit 1
}
