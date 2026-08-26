#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

required_files=(
  AGENTS.md
  README.md
  docs/architecture.md
  docs/contract.md
  docs/preservation.md
  docs/scope.md
  docs/storage.md
  goal/README.md
  goal/00_SCOPE_AND_PRESERVATION.md
  goal/01_CLEAN_RESET.md
  goal/01B_LEGACY_DISPOSITION_AND_PURGE.md
  goal/02_COMMON_CONTRACT_AND_TOOLING.md
  goal/03_AWS.md
  goal/04_GCP.md
  goal/05_AZURE.md
  goal/06_CROSS_CLOUD_ACCEPTANCE.md
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    printf 'ERROR: required file is missing: %s\n' "$required_file" >&2
    exit 1
  fi
done

for forbidden_path in artifacts cloud-init configs prompts src terraform tofu; do
  if git ls-files -- "$forbidden_path" | grep -q .; then
    printf 'ERROR: legacy tracked path remains: %s\n' "$forbidden_path" >&2
    exit 1
  fi
done

if git ls-files '*.py' 'requirements*.txt' 'pyproject.toml' | grep -q .; then
  printf 'ERROR: tracked Python/ML project files remain in the infrastructure repository.\n' >&2
  exit 1
fi

image_reference="$(sed -n 's/^ML_IMAGE=//p' .env.example)"
if [[ ! "$image_reference" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
  printf 'ERROR: .env.example must demonstrate an OCI image pinned by sha256 digest.\n' >&2
  exit 1
fi

if find infra -type f \( -name '*.tf' -o -name '*.tofu' \) -print -quit | grep -q .; then
  printf 'ERROR: Goal 01 must not contain a runnable provider implementation.\n' >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  printf 'ERROR: repository checks require ripgrep (rg).\n' >&2
  exit 1
fi

link_failure=0
while IFS=: read -r source_file source_line link_target; do
  [[ -n "$source_file" && -n "$link_target" ]] || continue
  resolved_path="$(realpath -m "$(dirname "$source_file")/$link_target")"
  if [[ ! -e "$resolved_path" ]]; then
    printf 'ERROR: broken Markdown link: %s:%s -> %s\n' \
      "$source_file" "$source_line" "$link_target" >&2
    link_failure=1
  fi
done < <(
  rg --no-heading --line-number -o \
    '\]\(([^)#]+\.md)(?:#[^)]+)?\)' \
    --replace '$1' \
    README.md AGENTS.md docs goal infra shared scripts tests
)

if ((link_failure != 0)); then
  exit 1
fi

bash -n scripts/check-repository.sh
git diff --check
git diff --cached --check

printf 'Repository baseline checks passed. No cloud command was executed.\n'
