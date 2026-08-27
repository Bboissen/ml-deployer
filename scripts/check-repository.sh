#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

required_files=(
  AGENTS.md
  README.md
  docs/architecture.md
  docs/contract.md
  docs/operations/interface.md
  docs/operations/oci-conformance.md
  docs/operations/aws-platform-acceptance.md
  docs/operations/rights-readiness.md
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
  shared/bootstrap/README.md
  shared/bootstrap/deadline-marker.sh
  shared/bootstrap/guest-runner.sh
  shared/conformance/README.md
  shared/conformance/oci-ml-smoke/.dockerignore
  shared/conformance/oci-ml-smoke/Dockerfile
  shared/conformance/oci-ml-smoke/conformance.py
  shared/conformance/oci-ml-smoke/requirements.in
  shared/conformance/oci-ml-smoke/requirements.lock
  shared/conformance/oci-ml-smoke/run-spec.example.json
  shared/contracts/command-result.schema.json
  shared/contracts/completion-receipt.schema.json
  shared/contracts/deployment-index.schema.json
  shared/contracts/local-execution-receipt.schema.json
  shared/contracts/resource-profiles.json
  shared/contracts/result-manifest.schema.json
  shared/contracts/result-manifest-fixtures/valid-conformance.json
  shared/contracts/runner-request.schema.json
  shared/contracts/fixtures/valid-aws.json
  shared/contracts/fixtures/valid-gcp.json
  shared/contracts/fixtures/valid-azure.json
  shared/contracts/fixtures/invalid-arbitrary-shell.json
  shared/contracts/fixtures/invalid-deployment-id.json
  shared/contracts/fixtures/invalid-fractional-runtime.json
  shared/contracts/fixtures/invalid-interruptible.json
  shared/contracts/fixtures/invalid-mutable-tag.json
  shared/contracts/fixtures/invalid-provider-binding.json
  shared/contracts/fixtures/invalid-secret-field.json
  shared/contracts/fixtures/invalid-signed-uri.json
  shared/contracts/fixtures/invalid-unbounded-runtime.json
  shared/contracts/receipt-fixtures/valid-aws.json
  shared/contracts/receipt-fixtures/valid-gcp.json
  shared/contracts/receipt-fixtures/valid-azure.json
  shared/contracts/receipt-fixtures/valid-bootstrap-failed-aws.json
  shared/contracts/receipt-fixtures/invalid-backend-binding.json
  shared/contracts/receipt-fixtures/invalid-deadline-window.json
  shared/contracts/receipt-fixtures/invalid-profile-floor.json
  shared/contracts/receipt-fixtures/invalid-publisher-identity.json
  shared/contracts/receipt-fixtures/invalid-success-exit.json
  shared/contracts/receipt-fixtures/invalid-success-after-deadline.json
  shared/contracts/receipt-fixtures/invalid-terminal.json
  shared/contracts/index-fixtures/valid-aws.json
  shared/contracts/index-fixtures/invalid-backend-binding.json
  shared/contracts/command-fixtures/valid-doctor.json
  shared/contracts/command-fixtures/invalid-null-destroy.json
  shared/contracts/command-fixtures/invalid-pass-failed-check.json
  shared/contracts/command-fixtures/invalid-pass-null-scope.json
  shared/contracts/command-fixtures/invalid-secret-evidence.json
  scripts/validate-runner-request.sh
  scripts/hash-runner-request.sh
  scripts/validate-completion-receipt.sh
  scripts/validate-deployment-index.sh
  scripts/validate-command-result.sh
  scripts/validate-result-manifest.sh
  scripts/load-cloud-env.sh
  scripts/oci/build-conformance-image.sh
  scripts/oci/verify-provider-digests.sh
  scripts/aws/validate-platform-live.sh
  scripts/aws/validate-platform-iam-simulation.sh
  tests/bootstrap/test-guest-runner.sh
  tests/bootstrap/fixtures/docker
  tests/conformance/test-oci-ml-smoke.sh
  tests/conformance/test-oci-tools.sh
  tests/conformance/fixtures/docker
  tests/contracts/test-runner-contract.sh
  tests/contracts/test-completion-receipt.sh
  tests/contracts/test-deployment-index.sh
  tests/contracts/test-command-result.sh
  tests/contracts/test-result-manifest.sh
  tests/aws/test-platform-plan.sh
  tests/aws/test-platform-iam-contract.sh
  tests/aws/test-platform-live-validator.sh
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    printf 'ERROR: required file is missing: %s\n' "$required_file" >&2
    exit 1
  fi
done

for forbidden_path in artifacts cloud-init configs prompts src terraform tofu; do
  if [[ -e "$forbidden_path" || -L "$forbidden_path" ]]; then
    printf 'ERROR: forbidden legacy workspace path remains: %s\n' "$forbidden_path" >&2
    exit 1
  fi
done

if find . -xdev -mindepth 1 \
  -not -path './.git' -not -path './.git/*' \
  -not -path './shared/conformance/oci-ml-smoke/conformance.py' \
  \( -name '*.py' -o -name 'requirements*.txt' -o -name 'pyproject.toml' \) \
  -print -quit | grep -q .; then
  printf 'ERROR: Python/ML project files remain in the infrastructure repository.\n' >&2
  exit 1
fi

if find . -xdev -mindepth 1 \
  -not -path './.git' -not -path './.git/*' \
  \( -name '.terraform' -o -name '.venv' -o -name '__pycache__' \
     -o -name '.pytest_cache' -o -name '.ruff_cache' -o -name '*.tfstate' \
     -o -name '*.tfstate.backup' -o -name '*.tfplan' -o -name '*.pyc' \) \
  -print -quit | grep -q .; then
  printf 'ERROR: generated provider, Python or runtime material remains in the workspace.\n' >&2
  exit 1
fi

oci_repository="$(sed -n 's/^OCI_REPOSITORY=//p' .env.example)"
oci_digest="$(sed -n 's/^OCI_DIGEST=//p' .env.example)"
if [[ ! "$oci_repository" =~ ^[a-z0-9.-]+/[a-z0-9._/-]+$ ]] \
  || [[ "$oci_repository" == *'@'* ]] \
  || [[ "$oci_digest" != sha256:* ]] \
  || [[ ! "$oci_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf 'ERROR: .env.example must separate a tagless OCI repository from a sha256 digest.\n' >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  printf 'ERROR: repository checks require ripgrep (rg).\n' >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: repository checks require jq.\n' >&2
  exit 1
fi

while IFS= read -r json_file; do
  jq -e . "$json_file" >/dev/null
done < <(find shared/contracts -type f -name '*.json' -print | LC_ALL=C sort)

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

while IFS= read -r shell_file; do
  bash -n "$shell_file"
done < <(find scripts shared tests -type f -name '*.sh' -print | LC_ALL=C sort)

bash scripts/load-cloud-env.sh invalid >/dev/null 2>&1 && {
  printf 'ERROR: cloud environment loader accepted an unknown provider.\n' >&2
  exit 1
}

bash tests/contracts/test-runner-contract.sh
bash tests/contracts/test-completion-receipt.sh
bash tests/contracts/test-deployment-index.sh
bash tests/contracts/test-command-result.sh
bash tests/contracts/test-result-manifest.sh
bash tests/bootstrap/test-guest-runner.sh
bash tests/conformance/test-oci-ml-smoke.sh
bash tests/conformance/test-oci-tools.sh
git diff --check
git diff --cached --check

printf 'Repository and contract checks passed. No cloud command was executed.\n'
