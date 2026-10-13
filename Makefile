SHELL := /bin/bash

TOFU ?= tofu
WORKSPACE_PYTHON ?= $(CURDIR)/.tools/workspace-venv/bin/python
export WORKSPACE_PYTHON

.DEFAULT_GOAL := guide
PROJECT ?=
FRESH ?= 0
DEBUG ?= 0
export PROJECT

.PHONY: aws-workstation-test aws-automation-test
.PHONY: remote
.PHONY: help-all

.PHONY: guide help check workspace-test workspace-test-setup aws-project-config-test historical-check repository-check contract-test conformance-test dummy-operator-test oci-conformance-build dummy-image-check dummy-image-build dummy-image-run-local dummy-lock-refresh dummy-preflight dummy-publication-review dummy-publish dummy-plan dummy-apply dummy-observe dummy-receipt-publish dummy-receipt-check dummy-destroy-plan dummy-destroy dummy-post-destroy-check dummy-cross-cloud-acceptance scaffold-test aws-platform-plan-test aws-platform-live-check cloud-env cloud-env-command fmt fmt-check

remote: ## Run setup here; show instructions for opening the guide on another device.
guide: ## Guided first use: tools, project questions, native login and companion (PROJECT=path, FRESH=1, DEBUG=1).
guide remote:
	@env -u WORKSPACE_PYTHON bash ./workspace guide "$${PROJECT:-$${HOME}/aws-workspace/demo/project.json}" $(if $(filter remote,$@),--remote) $(if $(filter 1,$(FRESH)),--fresh) $(if $(filter 1,$(DEBUG)),--debug)

help: ## Show first-use, remote and repair commands.
	@printf '\nAWS workspace\n\n'
	@printf '  %-42s %s\n' \
		'make' 'Start or resume guided setup' \
		'make remote' 'Run setup here; guide in your laptop browser' \
		'make PROJECT=/path/project.json' 'Choose the project configuration' \
		'make FRESH=1' 'Rebuild tools; keep settings and logins' \
		'make DEBUG=1' 'Show detailed diagnostics' \
		'make help-all' 'List development and infrastructure commands'
	@printf '\nAnswer setup questions in this terminal. Over SSH, run the printed tunnel\ncommand on your laptop outside SSH, then open the guide link there.\n\n'

help-all: ## Show all repository commands.
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | sed 's/:.*##/: /' | sort

check: repository-check workspace-test aws-automation-test scaffold-test fmt-check ## Validate workspace foundation and existing roots without cloud account APIs.

workspace-test-setup: ## Install the locked Python 3.13 validation/example environment (downloads packages).
	@command -v uv >/dev/null 2>&1 || { echo 'ERROR: uv is required.' >&2; exit 2; }
	@uv venv --python 3.13 .tools/workspace-venv
	@uv pip sync --python .tools/workspace-venv/bin/python --only-binary :all: --require-hashes shared/workspace/requirements.lock

workspace-test: ## Run workspace records, readiness and deterministic NumPy/pandas checks offline.
	@test -x "$(WORKSPACE_PYTHON)" || { echo 'ERROR: run make workspace-test-setup first or set WORKSPACE_PYTHON.' >&2; exit 2; }
	@PYTHONDONTWRITEBYTECODE=1 "$(WORKSPACE_PYTHON)" -B tests/aws/run-offline.py tests/workspace/test_workspace.py

aws-project-config-test: ## Check short AWS project configuration and operation records offline.
	@PYTHONDONTWRITEBYTECODE=1 "$(WORKSPACE_PYTHON)" tests/aws/run-offline.py tests/aws/test-workspace-config.py

aws-workstation-test: ## Check workstation bootstrap and assisted login offline; never downloads or logs in.
	@PYTHONDONTWRITEBYTECODE=1 "$(WORKSPACE_PYTHON)" tests/aws/run-offline.py tests/aws/test-workstation-setup.py

aws-automation-test: ## Run AWS installer/config/deploy/policy offline checks with verified cleanup
	@PYTHONDONTWRITEBYTECODE=1 "$(WORKSPACE_PYTHON)" -B tests/aws/run-offline.py

historical-check: contract-test conformance-test dummy-operator-test ## Check preserved batch/demo compatibility explicitly; no cloud APIs.

repository-check: ## Check repository structure, documents, JSON and shell syntax.
	@bash scripts/check-repository.sh

contract-test: ## Run the offline provider-neutral request and guest contract tests.
	@bash tests/contracts/test-runner-contract.sh
	@bash tests/contracts/test-completion-receipt.sh
	@bash tests/contracts/test-deployment-index.sh
	@bash tests/contracts/test-command-result.sh
	@bash tests/contracts/test-result-manifest.sh
	@bash tests/bootstrap/test-guest-runner.sh

conformance-test: ## Validate the OCI ML smoke source and dependency contract without running it.
	@bash tests/conformance/test-oci-ml-smoke.sh
	@bash tests/conformance/test-oci-tools.sh

dummy-operator-test: ## Exercise fail-closed shared operator dispatch without provider adapters.
	@bash tests/dummy/test-operator-interface.sh
	@bash tests/dummy/test-cross-cloud-acceptance.sh

oci-conformance-build: conformance-test ## Build/import the linux/amd64 smoke image locally; never pushes or runs it.
	@bash scripts/oci/build-conformance-image.sh

dummy-image-check: conformance-test dummy-operator-test ## Validate the tool-complete dummy source, lock, fixture, and operator boundary.

dummy-image-build: dummy-image-check ## Build the pinned linux/amd64 image locally; never pushes or runs it.
	@bash scripts/oci/build-conformance-image.sh

dummy-image-run-local: dummy-image-check ## Run the bounded image against a local provider-shaped object store.
	@bash scripts/oci/run-dummy-image-local.sh

dummy-lock-refresh: ## Resolve the linux/amd64 Python 3.14 lock using the reviewed uv command.
	@command -v uv >/dev/null 2>&1 || { echo 'ERROR: uv is required.' >&2; exit 2; }
	@UV_CACHE_DIR="$(CURDIR)/.tools/uv-cache" uv pip compile \
		shared/conformance/oci-ml-smoke/requirements.in \
		--python-version 3.14 \
		--python-platform x86_64-manylinux_2_28 \
		--resolution highest \
		--prerelease if-necessary \
		--generate-hashes \
		--only-binary :all: \
		--exclude-newer 2026-08-28 \
		--custom-compile-command 'make dummy-lock-refresh' \
		--output-file shared/conformance/oci-ml-smoke/requirements.lock

dummy-preflight: ## Dispatch one provider's read-only readiness checks; requires CLOUD and immutable hashes.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh preflight

dummy-publication-review: ## Dispatch one provider's immutable publication review; does not publish.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh publication-review

dummy-publish: ## Publish only with one provider adapter and an exact publication authorization artifact.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh publish

dummy-plan: ## Create one provider's runner saved plan; never applies it.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh plan

dummy-apply: ## Apply only SAVED_PLAN with an exact APPLY_AUTHORIZATION; never replans.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh apply

dummy-observe: ## Dispatch bounded observation for one exact DEPLOYMENT_ID.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh observe

dummy-receipt-publish: ## Publish one trusted receipt only from an exact authorized receipt bundle.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh receipt-publish

dummy-receipt-check: ## Verify one provider's exact FINAL_RECEIPT without mutation.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh receipt-check

dummy-destroy-plan: ## Create one provider's saved runner-only destroy plan; never applies it.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh destroy-plan

dummy-destroy: ## Apply only a saved destroy plan with exact DESTROY_AUTHORIZATION; never replans.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh destroy

dummy-post-destroy-check: ## Verify one exact runner is absent and persistent storage remains.
	@CLOUD="$(CLOUD)" bash scripts/dummy/dispatch.sh post-destroy-check

dummy-cross-cloud-acceptance: ## Validate final AWS/GCP/Azure receipts under EVIDENCE_ROOT; read-only.
	@test -n "$(EVIDENCE_ROOT)" || { echo 'ERROR: EVIDENCE_ROOT is required.' >&2; exit 2; }
	@bash scripts/dummy/validate-cross-cloud-acceptance.sh "$(EVIDENCE_ROOT)"

scaffold-test: ## Validate all provider scaffolds without cloud credentials or API calls.
	@PYTHONDONTWRITEBYTECODE=1 "$(WORKSPACE_PYTHON)" -B tests/aws/run-offline.py tests/aws/test-scaffold.sh tests/gcp/test-scaffold.sh tests/azure/test-scaffold.sh

aws-platform-plan-test: ## Validate a sealed AWS platform plan and its review receipt offline.
	@test -n "$(PLAN_JSON)" || { echo 'ERROR: set PLAN_JSON to the sealed tofu show -json artifact.' >&2; exit 2; }
	@test -n "$(REVIEW_RECEIPT)" || { echo 'ERROR: set REVIEW_RECEIPT to the Task B saved-plan review receipt.' >&2; exit 2; }
	@bash tests/aws/test-platform-plan.sh "$(PLAN_JSON)" "$(REVIEW_RECEIPT)"
	@bash tests/aws/test-platform-iam-contract.sh "$(PLAN_JSON)" "$(REVIEW_RECEIPT)"

aws-platform-live-check: ## Read-only validation of an applied AWS platform; never applies or writes test objects.
	@test -n "$(REVIEW_RECEIPT)" || { echo 'ERROR: set REVIEW_RECEIPT to the Task B saved-plan review receipt.' >&2; exit 2; }
	@test -n "$(PLATFORM_OUTPUTS)" || { echo 'ERROR: set PLATFORM_OUTPUTS to a captured tofu output -json artifact.' >&2; exit 2; }
	@test -n "$(AWS_PROFILE)" || { echo 'ERROR: set AWS_PROFILE to the reviewed temporary-login profile.' >&2; exit 2; }
	@bash scripts/aws/validate-platform-live.sh "$(REVIEW_RECEIPT)" "$(PLATFORM_OUTPUTS)" "$(AWS_PROFILE)"
	@bash scripts/aws/validate-platform-iam-simulation.sh "$(REVIEW_RECEIPT)" "$(AWS_PROFILE)"

cloud-env: ## Validate canonical .env values for CLOUD=aws, gcp or azure.
	@test -n "$(CLOUD)" || { echo 'ERROR: set CLOUD=aws, gcp or azure.' >&2; exit 2; }
	@bash scripts/load-cloud-env.sh "$(CLOUD)"

cloud-env-command: ## Print the command that propagates CLOUD into the current shell.
	@test -n "$(CLOUD)" || { echo 'ERROR: set CLOUD=aws, gcp or azure.' >&2; exit 2; }
	@case "$(CLOUD)" in aws|gcp|azure) ;; *) echo 'ERROR: CLOUD must be aws, gcp or azure.' >&2; exit 2;; esac
	@printf 'source scripts/load-cloud-env.sh %s\n' "$(CLOUD)"

fmt: ## Format OpenTofu files when provider roots exist.
	@if find infra -type f \( -name '*.tf' -o -name '*.tofu' \) -print -quit 2>/dev/null | grep -q .; then \
		$(TOFU) fmt -recursive infra; \
	else \
		echo 'No OpenTofu implementation exists yet.'; \
	fi

fmt-check: ## Check OpenTofu formatting when provider roots exist.
	@if find infra -type f \( -name '*.tf' -o -name '*.tofu' \) -print -quit 2>/dev/null | grep -q .; then \
		$(TOFU) fmt -check -recursive infra; \
	else \
		echo 'No OpenTofu implementation exists yet.'; \
	fi
