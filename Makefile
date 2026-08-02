SHELL := /usr/bin/env bash

PYTHON ?= $(shell if command -v mise >/dev/null 2>&1; then printf 'mise exec -- python'; elif command -v python3.12 >/dev/null 2>&1; then printf python3.12; else printf python3; fi)
DEV_PYTHON ?= $(shell if [ -x .venv/bin/python ]; then printf .venv/bin/python; else printf python3; fi)
SHELLCHECK ?= $(shell if [ -x .venv/bin/shellcheck ]; then printf .venv/bin/shellcheck; else printf shellcheck; fi)
WORKER_COUNT ?= 3
DO_WORKER_COUNT ?=
EXPECTED_WORKERS ?= 0
DATA_DIR ?= ./data/tune
OUT_DIR ?= ./artifacts/pulled
CONFIG ?= configs/tune_synthetic.yaml
TF_DIR := terraform/digitalocean-workers
TF ?= $(shell if command -v terraform >/dev/null 2>&1; then printf terraform; elif command -v tofu >/dev/null 2>&1; then printf tofu; elif command -v opentofu >/dev/null 2>&1; then printf opentofu; else printf terraform; fi)
TOFU ?= $(shell if command -v tofu >/dev/null 2>&1; then printf tofu; elif command -v opentofu >/dev/null 2>&1; then printf opentofu; else printf tofu; fi)
PROFILE ?= smoke-free
ROOT ?= tofu/gcp/training-node
PLAN ?=
AUTH ?=
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

.PHONY: storage-phase2-selftest
storage-phase2-selftest: ## Run the Phase 2 offline protocol/control acceptance suite.
	$(LOAD_ENV) if [ -f .venv/bin/activate ]; then . .venv/bin/activate; fi; PYTHONPATH=src python scripts/storage/phase2_selftest.py

.PHONY: lint-shell
lint-shell: ## Shell syntax check.
	bash -n scripts/head/*.sh scripts/local-vms/*.sh scripts/do/*.sh scripts/agentic/*.sh scripts/storage/*.sh scripts/gcp/*.sh scripts/aws/*.sh

.PHONY: dryrun
dryrun: ## Print current non-secret plan context.
	$(LOAD_ENV) bash scripts/dryrun.sh

.PHONY: install-head
install-head: ## Install Ray head dependencies on this machine.
	$(LOAD_ENV) PYTHON_BIN="$(PYTHON)" bash scripts/head/install_head.sh

.PHONY: head-start
head-start: ## Start Ray head on home server Tailscale IP.
	$(LOAD_ENV) bash scripts/head/start_head_service.sh

.PHONY: head-stop
head-stop: ## Stop Ray head.
	$(LOAD_ENV) bash scripts/head/stop_head.sh

.PHONY: head-lifecycle-check
head-lifecycle-check: ## Verify head start/stop is scoped to its own systemd cgroup.
	bash scripts/head/validate_head_lifecycle.sh

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
	$(LOAD_ENV) do_worker_count="$(DO_WORKER_COUNT)"; if [ -z "$$do_worker_count" ]; then do_worker_count="$${DO_WORKER_COUNT:-$${TF_VAR_worker_count:-1}}"; fi; TF="$(TF)" bash scripts/storage/storage.sh worker-plan "$$do_worker_count"

.PHONY: storage-init
storage-init: ## Initialize the persistent storage root with backend handling disabled.
	$(LOAD_ENV) TF="$(TF)" bash scripts/storage/storage.sh init

.PHONY: storage-validate
storage-validate: ## Validate storage HCL, policy, and the inactive backend example.
	$(LOAD_ENV) TF="$(TF)" bash scripts/storage/storage.sh validate

.PHONY: storage-plan
storage-plan: ## Plan and semantically verify exactly three persistent creates.
	$(LOAD_ENV) TF="$(TF)" bash scripts/storage/storage.sh plan

.PHONY: do-up
do-up: ## Create DO workers. Billable.
	$(LOAD_ENV) TF="$(TF)" bash scripts/storage/storage.sh guard-live-vpc
	$(LOAD_ENV) do_worker_count="$(DO_WORKER_COUNT)"; if [ -z "$$do_worker_count" ]; then do_worker_count="$${DO_WORKER_COUNT:-$${TF_VAR_worker_count:-1}}"; fi; cd $(TF_DIR) && $(TF) apply -auto-approve -var="worker_count=$$do_worker_count"
	$(LOAD_ENV) TF="$(TF)" bash scripts/do/render_inventory.sh

.PHONY: do-down
do-down: ## Destroy DO workers.
	$(LOAD_ENV) bash scripts/do/logout_workers.sh
	$(LOAD_ENV) cd $(TF_DIR) && $(TF) destroy -auto-approve

.PHONY: sync-data
sync-data: ## Sync a compact tune data slice to workers over Tailscale/public SSH inventory.
	$(LOAD_ENV) bash scripts/do/sync_data.sh $(DATA_DIR)

.PHONY: run-tune
run-tune: ## Run configured Tune job from home server.
	$(LOAD_ENV) bash scripts/do/run_tune.sh $(CONFIG)

.PHONY: pull-artifacts
pull-artifacts: ## Pull worker artifacts back.
	$(LOAD_ENV) bash scripts/do/pull_artifacts.sh $(OUT_DIR)

.PHONY: gcp-doctor gcp-account-check gcp-fmt gcp-validate gcp-test gcp-unit
gcp-doctor: ## Check local GCP workstation dependencies without cloud mutation.
	bash scripts/gcp/doctor.sh

gcp-account-check: ## Run the read-only GCP project prerequisite audit.
	$(LOAD_ENV) bash scripts/gcp/account_check.sh

gcp-fmt: ## Check formatting of all GCP OpenTofu roots.
	$(TOFU) fmt -check -recursive tofu/gcp tofu/modules

gcp-validate: ## Initialize without backends and validate every GCP root.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh validate-all

gcp-test: ## Run GCP policy and authorization unit tests.
	$(SHELLCHECK) scripts/gcp/*.sh
	$(DEV_PYTHON) -m ruff check scripts/gcp tests/gcp
	PYTHONPATH=scripts/gcp $(DEV_PYTHON) -m pytest -q tests/gcp

gcp-unit: ## Run dependency-free GCP unit tests.
	PYTHONPATH=scripts/gcp python3 -m unittest discover -s tests/gcp -p 'test_*.py'

.PHONY: gcp-bootstrap-init gcp-bootstrap-plan gcp-storage-init gcp-storage-plan
gcp-bootstrap-init: ## Initialize the local-state GCP bootstrap root.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh init bootstrap

gcp-bootstrap-plan: ## Save and policy-check a non-creating bootstrap plan.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh plan bootstrap bootstrap

gcp-storage-init: ## Initialize the GCP storage root using the partial backend.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh init storage

gcp-storage-plan: ## Save and policy-check the persistent GCS storage plan.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh plan storage storage

.PHONY: gcp-network-init gcp-network-plan gcp-compute-init gcp-compute-plan
gcp-network-init: ## Initialize the GCP network root using the partial backend.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh init network

gcp-network-plan: ## Save and policy-check the persistent GCP network plan.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh plan network network

gcp-compute-init: ## Initialize the disposable training-node root.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh init training-node

gcp-compute-plan: ## Save and policy-check one disposable VM plan.
	$(LOAD_ENV) TOFU="$(TOFU)" PROFILE="$(PROFILE)" bash scripts/gcp/tofu.sh plan training-node compute

.PHONY: gcp-authorize gcp-up gcp-verify gcp-down gcp-audit
gcp-authorize: ## Issue a local one-use authorization for an exact reviewed plan.
	$(LOAD_ENV) python3 scripts/gcp/authorization.py issue --root "$(ROOT)" --profile "$(PROFILE)" --plan "$(PLAN)"

gcp-up: ## Apply one exact authorized GCP plan; may create billable resources.
	$(LOAD_ENV) TOFU="$(TOFU)" python3 scripts/gcp/authorization.py apply --root "$(ROOT)" --profile "$(PROFILE)" --plan "$(PLAN)" --authorization "$(AUTH)"

gcp-verify: ## Run read-only post-apply verification for the active GCP run.
	$(LOAD_ENV) bash scripts/gcp/audit_resources.sh --verify-smoke

gcp-down: ## Destroy disposable training compute only; persistent roots are refused.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/gcp/tofu.sh destroy-compute

gcp-audit: ## Record a read-only audit of GCP disposable resources.
	$(LOAD_ENV) bash scripts/gcp/audit_resources.sh --json

.PHONY: aws-doctor aws-account-check aws-fmt aws-validate aws-test
aws-doctor: ## Check local AWS workstation dependencies without cloud mutation.
	$(LOAD_ENV) bash scripts/aws/doctor.sh

aws-account-check: ## Run the read-only AWS account prerequisite audit.
	$(LOAD_ENV) bash scripts/aws/account_check.sh

aws-fmt: ## Check formatting of all AWS OpenTofu roots.
	$(TOFU) fmt -check -recursive tofu/aws

aws-validate: ## Initialize without backends and validate every AWS root.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh validate-all

aws-test: ## Run AWS shell, Python, profile-contract, and source-policy tests.
	$(SHELLCHECK) scripts/aws/*.sh
	$(DEV_PYTHON) -m ruff check scripts/aws tests/aws
	$(DEV_PYTHON) -m pytest -q tests/aws

.PHONY: aws-bootstrap-init aws-bootstrap-plan aws-storage-init aws-storage-plan
aws-bootstrap-init: ## Initialize the code-only AWS bootstrap root.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh init bootstrap

aws-bootstrap-plan: ## Save a non-creating AWS bootstrap scaffold plan.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh plan bootstrap

aws-storage-init: ## Initialize the AWS storage root after Goal 03 acceptance.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh init storage

aws-storage-plan: ## Save a non-creating AWS storage scaffold plan.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh plan storage

.PHONY: aws-network-init aws-network-plan aws-compute-init aws-compute-plan aws-spot-init aws-spot-plan
aws-network-init: ## Initialize the AWS network root after Goal 03 acceptance.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh init network

aws-network-plan: ## Save a non-creating AWS network scaffold plan.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh plan network

aws-compute-init: ## Initialize the direct AWS training-node root after Goal 03 acceptance.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh init training-node

aws-compute-plan: ## Save a non-creating direct AWS compute scaffold plan.
	$(LOAD_ENV) PROFILE="$(PROFILE)" TOFU="$(TOFU)" bash scripts/aws/tofu.sh plan training-node

aws-spot-init: ## Initialize the recoverable AWS Spot root after Goal 09A acceptance.
	$(LOAD_ENV) TOFU="$(TOFU)" bash scripts/aws/tofu.sh init spot-runner

aws-spot-plan: ## Save a non-creating AWS Spot scaffold plan.
	$(LOAD_ENV) PROFILE="$(PROFILE)" CONFIG="$(CONFIG)" TOFU="$(TOFU)" bash scripts/aws/tofu.sh plan spot-runner

.PHONY: aws-authorize aws-up aws-spot-status aws-spot-cancel aws-verify aws-down aws-audit
aws-authorize: ## Fail closed until the AWS exact-plan authorization milestone is implemented.
	bash scripts/aws/mutation_gate.sh authorize

aws-up: ## Fail closed; AWS apply is not implemented or authorized in Goals 01-02.
	bash scripts/aws/mutation_gate.sh apply

aws-spot-status: ## Fail closed until the recoverable Spot controller exists.
	bash scripts/aws/mutation_gate.sh spot-status

aws-spot-cancel: ## Fail closed until the recoverable Spot controller exists.
	bash scripts/aws/mutation_gate.sh spot-cancel

aws-verify: ## Run the current read-only AWS account and resource audit.
	$(LOAD_ENV) bash scripts/aws/account_check.sh --json

aws-down: ## Fail closed; there is no AWS compute lifecycle in Goals 01-02.
	bash scripts/aws/mutation_gate.sh destroy

aws-audit: ## Record the current read-only AWS account and resource audit.
	$(LOAD_ENV) bash scripts/aws/account_check.sh --json
