#!/usr/bin/env bash
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
  README.md
  Makefile
  evidence/.gitignore
  evidence/README.md
  shared/workspace/schema.json
  shared/workspace/toolbox.json
  docs/workspace.md
  docs/architecture.md
  docs/contract.md
  docs/opentofu-architecture.html
  docs/operations/lifecycle.md
  goal/README.md
  shared/contracts/runner-request.schema.json
  shared/contracts/completion-receipt.schema.json
  shared/contracts/result-manifest.schema.json
  shared/bootstrap/guest-runner.sh
  shared/conformance/oci-ml-smoke/Dockerfile
  tests/aws/test-scaffold.sh
  tests/gcp/test-scaffold.sh
  tests/azure/test-scaffold.sh
)

for required_file in "${required_files[@]}"; do
  [[ -f "$required_file" ]] || fail "required file is missing: ${required_file}"
done

mapfile -t visible_evidence_files < <(
  git ls-files --cached --others --exclude-standard evidence | LC_ALL=C sort
)
[[ "${visible_evidence_files[*]}" == 'evidence/.gitignore evidence/README.md' ]] ||
  fail 'only evidence layout documentation may be visible to Git'
git check-ignore -q evidence/aws/LOCAL-RUNTIME-PROBE || fail 'local evidence is not ignored'
if rg -q --glob '!check-repository.sh' '\.dummy-runtime|/home/user/\.cache/opentofu' scripts tests; then
  fail 'runtime/cache writers must use portable ignored paths'
fi

for provider_name in aws gcp azure; do
  [[ -f "infra/${provider_name}/README.md" ]] ||
    fail "missing provider README: ${provider_name}"
  for root_name in bootstrap platform runner; do
    root_path="infra/${provider_name}/${root_name}"
    [[ -d "$root_path" ]] || fail "missing root: ${root_path}"
    [[ -f "${root_path}/versions.tf" ]] || fail "missing versions.tf: ${root_path}"
    [[ -f "${root_path}/provider.tf" ]] || fail "missing provider.tf: ${root_path}"
    [[ -f "${root_path}/.terraform.lock.hcl" ]] ||
      fail "missing dependency lock: ${root_path}"
  done
done

for forbidden_path in artifacts cloud-init configs prompts src terraform tofu; do
  [[ ! -e "$forbidden_path" && ! -L "$forbidden_path" ]] ||
    fail "forbidden legacy workspace path remains: ${forbidden_path}"
done

if git ls-files 'docs/ml-project/**' | grep -q .; then
  fail 'tracked ML-project material is outside this infrastructure repository boundary'
fi

if find . -xdev -mindepth 1 \
  -not -path './.git' -not -path './.git/*' \
  -not -path './evidence' -not -path './evidence/*' \
  -not -path './.tools' -not -path './.tools/*' \
  -not -path './docs/ml-project' -not -path './docs/ml-project/*' \
  -not -path './scripts/workspace/validate.py' \
  -not -path './scripts/workspace/probe-toolbox.py' \
  -not -path './scripts/aws/workspace-e2e.py' \
  -not -path './scripts/aws/workspace.py' \
  -not -path './scripts/aws/workspace-config.py' \
  -not -path './scripts/aws/workspace-onboarding.py' \
  -not -path './scripts/aws/workspace-ingest.py' \
  -not -path './tests/aws/test-workspace-ingest.py' \
  -not -path './scripts/aws/workspace_ram.py' \
  -not -path './tests/aws/run-offline.py' \
  -not -path './tests/aws/test-workspace-onboarding.py' \
  -not -path './scripts/aws/workstation-auth.py' \
  -not -path './tests/aws/test-workstation-setup.py' \
  -not -path './tests/aws/test-workspace-config.py' \
  -not -path './tests/workspace/test_workspace.py' \
  -not -path './shared/workspace/example/example.py' \
  -not -path './shared/conformance/oci-ml-smoke/conformance.py' \
  -not -path './shared/conformance/oci-ml-smoke/generate-fixture.py' \
  -not -path './shared/conformance/oci-ml-smoke/test_conformance.py' \
  \( -name '*.py' -o -name 'requirements*.txt' -o -name 'pyproject.toml' \) \
  -print -quit | grep -q .; then
  fail 'Python or ML project files remain outside the bounded infrastructure validation/acceptance files'
fi

if find . -xdev -mindepth 1 \
  -not -path './.git' -not -path './.git/*' \
  -not -path './evidence' -not -path './evidence/*' \
  -not -path './.tools' -not -path './.tools/*' \
  -not -path './docs/ml-project' -not -path './docs/ml-project/*' \
  \( -name '.terraform' -o -name '.venv' -o -name '__pycache__' \
     -o -name '.pytest_cache' -o -name '.ruff_cache' -o -name '*.tfstate' \
     -o -name '*.tfstate.backup' -o -name '*.tfplan' -o -name '*.pyc' \) \
  -print -quit | grep -q .; then
  fail 'generated provider, Python, plan, state, or runtime material remains'
fi

oci_repository="$(sed -n 's/^OCI_REPOSITORY=//p' .env.example)"
oci_digest="$(sed -n 's/^OCI_DIGEST=//p' .env.example)"
if [[ ! "$oci_repository" =~ ^[a-z0-9.-]+/[a-z0-9._/-]+$ ]] \
  || [[ "$oci_repository" == *'@'* ]] \
  || [[ ! "$oci_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  fail '.env.example must separate a tagless OCI repository and sha256 digest'
fi

while IFS= read -r json_file; do
  jq -e . "$json_file" >/dev/null
done < <(find shared/contracts shared/workspace -type f -name '*.json' -print | LC_ALL=C sort)

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
    --glob '!docs/ml-project/**' \
    README.md AGENTS.md docs goal infra shared scripts tests
)
((link_failure == 0)) || exit 1

while IFS= read -r shell_file; do
  bash -n "$shell_file"
done < <(find scripts shared tests -type f -name '*.sh' -print | LC_ALL=C sort)

if bash scripts/load-cloud-env.sh invalid >/dev/null 2>&1; then
  fail 'cloud environment loader accepted an unknown provider'
fi

git diff --check
git diff --cached --check

printf 'check-repository: PASS (structure only; no cloud command executed)\n'
