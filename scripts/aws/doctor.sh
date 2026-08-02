#!/usr/bin/env bash
set -Eeuo pipefail

missing=0

version_of() {
  local command_name="$1"
  shift
  if command -v "$command_name" >/dev/null 2>&1; then
    printf 'PASS tool=%s path=%s version=%s\n' \
      "$command_name" "$(command -v "$command_name")" "$("$@" 2>&1 | head -n 1)"
  else
    printf 'FAIL required tool is missing: %s\n' "$command_name" >&2
    missing=1
  fi
}

version_of aws aws --version
version_of tofu tofu version
version_of git git --version
version_of make make --version
version_of python3 python3 --version
version_of uv uv --version
version_of jq jq --version

if command -v shellcheck >/dev/null 2>&1; then
  printf 'PASS tool=shellcheck version=%s\n' "$(shellcheck --version | awk -F': ' '/^version:/{print $2}')"
elif [[ -x .venv/bin/shellcheck ]]; then
  printf 'PASS tool=shellcheck path=.venv/bin/shellcheck version=%s\n' "$(.venv/bin/shellcheck --version | awk -F': ' '/^version:/{print $2}')"
else
  printf '%s\n' 'FAIL required tool is missing: shellcheck' >&2
  missing=1
fi

for python_tool in ruff pytest; do
  if command -v "$python_tool" >/dev/null 2>&1; then
    printf 'PASS tool=%s version=%s\n' "$python_tool" "$($python_tool --version 2>&1 | head -n 1)"
  elif [[ -x ".venv/bin/$python_tool" ]]; then
    printf 'PASS tool=%s path=.venv/bin/%s version=%s\n' \
      "$python_tool" "$python_tool" "$(".venv/bin/$python_tool" --version 2>&1 | head -n 1)"
  else
    printf 'FAIL required tool is missing: %s\n' "$python_tool" >&2
    missing=1
  fi
done

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)'; then
  printf '%s\n' 'FAIL Python 3.12 or newer is required' >&2
  missing=1
fi

if command -v aws >/dev/null 2>&1 && ! aws --version 2>&1 | grep -Eq '^aws-cli/2\.'; then
  printf '%s\n' 'FAIL AWS CLI v2 is required' >&2
  missing=1
fi

if [[ -n "${AWS_ACCESS_KEY_ID:-}" || -n "${AWS_SECRET_ACCESS_KEY:-}" || -n "${AWS_SESSION_TOKEN:-}" ]]; then
  printf '%s\n' 'FAIL static/provider-chain AWS credential variables are set; use AWS CLI aws login for this path' >&2
  missing=1
fi

((missing == 0)) || {
  printf '%s\n' 'aws-doctor: fix local prerequisites; no AWS API call or mutation was attempted.' >&2
  exit 1
}

printf '%s\n' 'aws-doctor: PASS; no AWS API call or mutation was attempted.'
