# Makefile — automation for the Voting App deploy pipeline.
#
# Wraps the four scripts in scripts/ (build.sh, deploy.sh, verify.sh, cleanup.sh).
# All script environment variables (CLUSTER, REGISTRY, REGISTRY_PORT, DELETE_CLUSTER,
# ...) pass through automatically: export them before `make`, or
# assign them on the make command line (e.g. `make deploy REGISTRY=1`).

SHELL := /bin/bash
.EXPORT_ALL_VARIABLES:

# Tenants never run in `default` (settled by S17's review): the demo app lives in the
# voting-a / voting-b overlays, and `default` belongs to the control plane - the controller
# and its `jit-ipam` ledger. Both defaults below follow from that rule. Deploying the base
# kustomization would put the app in `default`, whose Ingress would then fight `voting-a` for
# `vote.localhost`, and the J-suite's PREREQ refuses to run in that state ("one namespace per
# demo host") - which is how this was found (docs/evidence/s17-cold-path-order.log).
# Override either on the command line as before: `make all NS=voting-b KUSTOMIZE_DIR=./kustomize/overlays/voting-b`.
NS ?= voting-a
KUSTOMIZE_DIR ?= ./kustomize/overlays/voting-a

SCRIPTS := scripts
BUILD   := $(SCRIPTS)/build.sh
DEPLOY  := $(SCRIPTS)/deploy.sh
VERIFY  := $(SCRIPTS)/verify.sh
CLEANUP := $(SCRIPTS)/cleanup.sh

.DEFAULT_GOAL := help

.PHONY: help
help: ## List targets (this help)
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Env vars (passed to the underlying scripts): CLUSTER, REGISTRY, REGISTRY_PORT,"
	@echo "          DELETE_CLUSTER. Set them with 'VAR=value make <target>' or 'make <target> VAR=value'."

# --- Build -----------------------------------------------------------------

.PHONY: build
build: ## Build the 3 images (vote/worker/result, linux/arm64) and load them into the cluster
	@./$(BUILD)

# --- Deploy ----------------------------------------------------------------

.PHONY: deploy
deploy: ## Create cluster (if missing), build + load images, apply Kustomize, wait for ready
	@./$(DEPLOY)

.PHONY: up
up: deploy ## Idempotent deploy (alias for deploy)

# --- Verify ----------------------------------------------------------------

.PHONY: verify
verify: ## Run R1–R17, print PASS/FAIL summary, append to .workflow/verify.md
	@./$(VERIFY)

.PHONY: test
test: verify ## Alias for verify

# --- Full workflow ---------------------------------------------------------

.PHONY: all
all: deploy verify ## Deploy then verify (the normal build → verify loop)

# --- Teardown --------------------------------------------------------------

.PHONY: clean
clean: ## Delete the deployed Kubernetes resources (safe to repeat)
	@./$(CLEANUP)

.PHONY: down
down: clean ## Alias for clean

.PHONY: destroy
destroy: ## Full teardown: delete resources, then the k3d cluster
	@DELETE_CLUSTER=1 ./$(CLEANUP)

.PHONY: status
status: ## Show cluster pods, services, and ingress
	@kubectl get pods,svc,ingress
