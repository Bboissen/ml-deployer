SHELL := /bin/bash

TOFU ?= tofu

.DEFAULT_GOAL := help

.PHONY: help check contract-test scaffold-test fmt fmt-check

help: ## Show available repository commands.
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | sed 's/:.*##/: /' | sort

check: ## Run offline repository checks; never contacts a cloud provider.
	@bash scripts/check-repository.sh

contract-test: ## Run the offline provider-neutral request and guest contract tests.
	@bash tests/contracts/test-runner-contract.sh
	@bash tests/contracts/test-completion-receipt.sh
	@bash tests/contracts/test-deployment-index.sh
	@bash tests/contracts/test-command-result.sh
	@bash tests/bootstrap/test-guest-runner.sh

scaffold-test: ## Validate all provider scaffolds without cloud credentials or API calls.
	@bash tests/aws/test-scaffold.sh
	@bash infra/gcp/tests/validate-offline.sh
	@bash tests/azure/test-scaffold.sh

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
