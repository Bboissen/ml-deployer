SHELL := /bin/bash

TOFU ?= tofu

.DEFAULT_GOAL := help

.PHONY: help check contract-test conformance-test oci-conformance-build scaffold-test aws-platform-plan-test aws-platform-live-check cloud-env cloud-env-command fmt fmt-check

help: ## Show available repository commands.
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | sed 's/:.*##/: /' | sort

check: ## Run offline repository checks; never contacts a cloud provider.
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

oci-conformance-build: conformance-test ## Build/import the linux/amd64 smoke image locally; never pushes or runs it.
	@bash scripts/oci/build-conformance-image.sh

scaffold-test: ## Validate all provider scaffolds without cloud credentials or API calls.
	@bash tests/aws/test-scaffold.sh
	@bash infra/gcp/tests/validate-offline.sh
	@bash tests/azure/test-scaffold.sh

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
