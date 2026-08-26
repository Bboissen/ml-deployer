SHELL := /bin/bash

TOFU ?= tofu

.DEFAULT_GOAL := help

.PHONY: help check fmt fmt-check

help: ## Show available repository commands.
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | sed 's/:.*##/: /' | sort

check: ## Run offline repository checks; never contacts a cloud provider.
	@bash scripts/check-repository.sh

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
