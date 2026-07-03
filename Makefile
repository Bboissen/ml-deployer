SHELL := /usr/bin/env bash

PYTHON ?= $(shell if command -v mise >/dev/null 2>&1; then printf 'mise exec -- python'; elif command -v python3.12 >/dev/null 2>&1; then printf python3.12; else printf python3; fi)
WORKER_COUNT ?= 3
DO_WORKER_COUNT ?=
EXPECTED_WORKERS ?= 0
DATA_DIR ?= ./data/tune
OUT_DIR ?= ./artifacts/pulled
CONFIG ?= configs/tune_synthetic.yaml
TF_DIR := terraform/digitalocean-workers
TF ?= $(shell if command -v terraform >/dev/null 2>&1; then printf terraform; elif command -v tofu >/dev/null 2>&1; then printf tofu; elif command -v opentofu >/dev/null 2>&1; then printf opentofu; else printf terraform; fi)
LOAD_ENV := set -a; [ ! -f .env ] || source .env; set +a;

.PHONY: help
help:
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | sed 's/:.*##/: /' | sort

.PHONY: venv
venv: ## Create Python virtualenv.
	$(PYTHON) -m venv .venv
	. .venv/bin/activate && pip install -U pip wheel && pip install -r requirements.txt && pip install -e .

.PHONY: python-check
python-check: ## Compile Python source files.
	if [ -f .venv/bin/activate ]; then . .venv/bin/activate; fi; python -m compileall src scripts

.PHONY: lint-shell
lint-shell: ## Shell syntax check.
	bash -n scripts/head/*.sh scripts/local-vms/*.sh scripts/do/*.sh scripts/agentic/*.sh

.PHONY: dryrun
dryrun: ## Print current non-secret plan context.
	$(LOAD_ENV) bash scripts/dryrun.sh

.PHONY: install-head
install-head: ## Install Ray head dependencies on this machine.
	$(LOAD_ENV) PYTHON_BIN="$(PYTHON)" bash scripts/head/install_head.sh

.PHONY: head-start
head-start: ## Start Ray head on home server Tailscale IP.
	$(LOAD_ENV) bash scripts/head/start_head.sh

.PHONY: head-stop
head-stop: ## Stop Ray head.
	$(LOAD_ENV) bash scripts/head/stop_head.sh

.PHONY: ray-status
ray-status: ## Show Ray cluster status and optionally verify expected workers.
	$(LOAD_ENV) bash scripts/head/ray_status.sh $(EXPECTED_WORKERS)

.PHONY: smoke
smoke: ## Run cluster smoke probe.
	$(LOAD_ENV) . .venv/bin/activate && python -m spotify_ray_infra.smoke --expected-workers $(EXPECTED_WORKERS)

.PHONY: tune-synth
tune-synth: ## Run synthetic Ray Tune workload.
	mkdir -p artifacts/live artifacts/ray_results
	$(LOAD_ENV) . .venv/bin/activate && python -m spotify_ray_infra.tune_synthetic --config $(CONFIG)

.PHONY: watch
watch: ## Watch live Ray Tune results continuously.
	$(LOAD_ENV) . .venv/bin/activate && python scripts/agentic/watch_results.py --events artifacts/live/trial_events.jsonl --out artifacts/live/latest_summary.md

.PHONY: watch-once
watch-once: ## Generate one live-result summary for subagents.
	$(LOAD_ENV) . .venv/bin/activate && python scripts/agentic/watch_results.py --events artifacts/live/trial_events.jsonl --out artifacts/live/latest_summary.md --once

.PHONY: local-lab-up
local-lab-up: ## Launch local Multipass worker VMs.
	$(LOAD_ENV) bash scripts/local-vms/create_local_lab.sh $(WORKER_COUNT)

.PHONY: local-lab-down
local-lab-down: ## Destroy local Multipass worker VMs.
	$(LOAD_ENV) bash scripts/local-vms/destroy_local_lab.sh

.PHONY: do-init
do-init: ## Initialize Terraform/OpenTofu for DO workers.
	$(LOAD_ENV) cd $(TF_DIR) && $(TF) init

.PHONY: do-validate
do-validate: ## Validate Terraform/OpenTofu for DO workers.
	$(LOAD_ENV) cd $(TF_DIR) && $(TF) fmt -check && $(TF) validate

.PHONY: do-plan
do-plan: ## Plan DO workers without creating resources.
	$(LOAD_ENV) do_worker_count="$(DO_WORKER_COUNT)"; if [ -z "$$do_worker_count" ]; then do_worker_count="$${DO_WORKER_COUNT:-$${TF_VAR_worker_count:-1}}"; fi; cd $(TF_DIR) && $(TF) plan -var="worker_count=$$do_worker_count"

.PHONY: do-up
do-up: ## Create DO workers. Billable.
	$(LOAD_ENV) do_worker_count="$(DO_WORKER_COUNT)"; if [ -z "$$do_worker_count" ]; then do_worker_count="$${DO_WORKER_COUNT:-$${TF_VAR_worker_count:-1}}"; fi; cd $(TF_DIR) && $(TF) apply -var="worker_count=$$do_worker_count"
	$(LOAD_ENV) TF="$(TF)" bash scripts/do/render_inventory.sh

.PHONY: do-down
do-down: ## Destroy DO workers.
	$(LOAD_ENV) cd $(TF_DIR) && $(TF) destroy

.PHONY: sync-data
sync-data: ## Sync a compact tune data slice to workers over Tailscale/public SSH inventory.
	$(LOAD_ENV) bash scripts/do/sync_data.sh $(DATA_DIR)

.PHONY: run-tune
run-tune: ## Run configured Tune job from home server.
	$(LOAD_ENV) bash scripts/do/run_tune.sh $(CONFIG)

.PHONY: pull-artifacts
pull-artifacts: ## Pull worker artifacts back.
	$(LOAD_ENV) bash scripts/do/pull_artifacts.sh $(OUT_DIR)
