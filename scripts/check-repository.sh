#!/usr/bin/env bash
# Static repository checks: layout, Markdown links, JSON, shell syntax. No cloud calls.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'check-repository: FAIL: %s\n' "$1" >&2
  exit 1
}

for command_name in git jq realpath rg; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required command is missing: ${command_name}"
done

required_files=(
  AGENTS.md
  CONTRIBUTING.md
  LICENSE
  README.md
  SECURITY.md
  Makefile
  workspace
  evidence/.gitignore
  evidence/README.md
  docs/aws-setup-guide.html
  docs/aws-setup-guide.js
  shared/workspace/schema.json
  shared/workspace/project.schema.json
  shared/workspace/toolbox.json
  shared/workspace/release.json
  infra/aws/README.md
  infra/aws/project.example.json
  scripts/aws/workstation-tools.lock.tsv
  scripts/aws/controller-requirements.lock
)

for required_file in "${required_files[@]}"; do
  [[ -f "$required_file" ]] || fail "required file is missing: ${required_file}"
done

for root_path in infra/aws/bootstrap/workspace infra/aws/platform infra/aws/platform/workspace infra/aws/runner/workspace; do
  [[ -d "$root_path" ]] || fail "missing root: ${root_path}"
  for name in versions.tf provider.tf .terraform.lock.hcl; do
    [[ -f "${root_path}/${name}" ]] || fail "missing ${name}: ${root_path}"
  done
done

mapfile -t visible_evidence_files < <(
  git ls-files --cached --others --exclude-standard evidence | LC_ALL=C sort
)
[[ "${visible_evidence_files[*]}" == 'evidence/.gitignore evidence/README.md' ]] ||
  fail 'only evidence layout documentation may be visible to Git'
git check-ignore -q evidence/aws/LOCAL-RUNTIME-PROBE || fail 'local evidence is not ignored'

if find . -xdev -mindepth 1 \
  -not -path './.git' -not -path './.git/*' \
  -not -path './evidence' -not -path './evidence/*' \
  -not -path './.tools' -not -path './.tools/*' \
  \( -name '.terraform' -o -name '.venv' -o -name '__pycache__' \
     -o -name '.pytest_cache' -o -name '*.tfstate' -o -name '*.tfstate.backup' \
     -o -name '*.tfplan' -o -name '*.pyc' \) \
  -print -quit | grep -q .; then
  fail 'generated provider, Python, plan, state, or runtime material remains'
fi

while IFS= read -r json_file; do
  jq -e . "$json_file" >/dev/null || fail "invalid JSON: ${json_file}"
done < <(git ls-files '*.json' | LC_ALL=C sort)

link_failure=0
while IFS=: read -r source_file source_line link_target; do
  [[ -n "$source_file" && -n "$link_target" ]] || continue
  [[ "$link_target" == *://* || "$link_target" == mailto:* ]] && continue
  resolved_path="$(realpath -m "$(dirname "$source_file")/$link_target")"
  if [[ ! -e "$resolved_path" ]]; then
    printf 'ERROR: broken Markdown link: %s:%s -> %s\n' \
      "$source_file" "$source_line" "$link_target" >&2
    link_failure=1
  fi
done < <(
  rg --no-heading --line-number -o \
    '\]\(([^)#]+)(?:#[^)]+)?\)' \
    --replace '$1' \
    --glob '*.md' \
    README.md AGENTS.md CONTRIBUTING.md SECURITY.md docs infra shared scripts tests
)
((link_failure == 0)) || exit 1

while IFS= read -r shell_file; do
  bash -n "$shell_file"
done < <(git ls-files '*.sh' | LC_ALL=C sort)
bash -n workspace

git diff --check
git diff --cached --check

printf 'check-repository: PASS (structure only; no cloud command executed)\n'
