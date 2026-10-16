SHELL := /bin/bash

TOFU ?= tofu
WORKSPACE_PYTHON ?= $(CURDIR)/.tools/workspace-venv/bin/python
export WORKSPACE_PYTHON

.DEFAULT_GOAL := guide
PROJECT ?=
FRESH ?= 0
DEBUG ?= 0
REPO ?=
DATASET ?=
export PROJECT REPO DATASET

.PHONY: guide remote help help-all check workspace-test-setup workspace-test aws-automation-test repository-check scaffold-test fmt fmt-check

remote: ## Run setup here; show instructions for opening the guide on another device.
guide: ## Guided first use: tools, project, native login and companion (PROJECT=path, REPO=owner/name, DATASET=path, FRESH=1, DEBUG=1).
guide remote:
	@env -u WORKSPACE_PYTHON bash ./workspace guide "$${PROJECT:-$${HOME}/aws-workspace/demo/project.json}" $${REPO:+--repo "$$REPO"} $${DATASET:+--dataset "$$DATASET"} $(if $(filter remote,$@),--remote) $(if $(filter 1,$(FRESH)),--fresh) $(if $(filter 1,$(DEBUG)),--debug)

help: ## Show first-use, remote and repair commands.
	@printf '\nAWS workspace\n\n'
	@printf '  %-42s %s\n' \
		'make' 'Start or resume guided setup' \
		'make remote' 'Run setup here; guide in your laptop browser' \
		'make PROJECT=/path/project.json' 'Choose the project configuration' \
		'make REPO=owner/name DATASET=path' 'Set up without questions (logins only)' \
		'make FRESH=1' 'Rebuild tools; keep settings and logins' \
		'make DEBUG=1' 'Show detailed diagnostics' \
		'make check' 'Run the offline test suite (developers)' \
		'make help-all' 'List every command'
	@printf '\nAnswer setup questions in this terminal. Over SSH, run the printed tunnel\ncommand on your laptop outside SSH, then open the guide link there.\n\n'

help-all: ## Show all repository commands.
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | sed 's/:.*##/: /' | sort

check: repository-check workspace-test aws-automation-test scaffold-test fmt-check ## Run every offline check; no cloud account APIs.

workspace-test-setup: ## Install the locked Python 3.13 test environment (downloads packages).
	@command -v uv >/dev/null 2>&1 || { echo 'ERROR: uv is required.' >&2; exit 2; }
	@uv venv --python 3.13 .tools/workspace-venv
	@uv pip sync --python .tools/workspace-venv/bin/python --only-binary :all: --require-hashes shared/workspace/requirements.lock
	@uv pip install --python .tools/workspace-venv/bin/python --only-binary :all: --require-hashes -r scripts/aws/controller-requirements.lock

workspace-test: ## Check workspace records, readiness probe and the deterministic example offline.
	@test -x "$(WORKSPACE_PYTHON)" || { echo 'ERROR: run make workspace-test-setup first or set WORKSPACE_PYTHON.' >&2; exit 2; }
	@PYTHONDONTWRITEBYTECODE=1 "$(WORKSPACE_PYTHON)" -B tests/aws/run-offline.py tests/workspace/test_workspace.py

aws-automation-test: ## Run the AWS installer/guide/config/deploy/lifecycle suites offline with verified cleanup.
	@PYTHONDONTWRITEBYTECODE=1 "$(WORKSPACE_PYTHON)" -B tests/aws/run-offline.py

repository-check: ## Check repository structure, Markdown links, JSON and shell syntax.
	@bash scripts/check-repository.sh

scaffold-test: ## Validate the AWS OpenTofu roots without credentials or API calls.
	@PYTHONDONTWRITEBYTECODE=1 "$(WORKSPACE_PYTHON)" -B tests/aws/run-offline.py tests/aws/test-scaffold.sh

fmt: ## Format OpenTofu files.
	@$(TOFU) fmt -recursive infra

fmt-check: ## Check OpenTofu formatting.
	@$(TOFU) fmt -check -recursive infra
