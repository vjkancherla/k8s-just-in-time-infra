# Makefile — root orchestration for the JIT infra PoC (build-plan S17).
#
# There are two halves and they are deliberately separate:
#
#   app/        the voting app's own build/deploy/verify loop  → app/Makefile
#   here        the JIT stack: MinIO, the runner, the CRD, the controller,
#               and the J1-J11 lifecycle suite
#
# The JIT targets are thin wrappers over scripts/jit-*.sh, the same idiom as
# app/Makefile: the logic lives in a script that can be read and run on its own.

SHELL := /bin/bash

SCRIPTS := scripts

.DEFAULT_GOAL := help

.PHONY: help
help: ## List targets (this help)
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  STEP=NN     for 'make check STEP=15'"
	@echo "  NS=<ns>     for 'make verify' (default: voting-a, the demo namespace)"

# --- The JIT stack ---------------------------------------------------------

.PHONY: jit-up
jit-up: ## MinIO + runner + CRD + controller (the out-of-cluster half)
	@./$(SCRIPTS)/jit-up.sh

.PHONY: jit-verify
jit-verify: ## Run the J1-J11 lifecycle suite -> .workflow/verify-jit.md (non-zero on FAIL)
	@./$(SCRIPTS)/verify-jit.sh

.PHONY: jit-down
jit-down: ## Remove the controller, the runner, MinIO and any leftover JIT containers
	@./$(SCRIPTS)/jit-down.sh

# --- The app ---------------------------------------------------------------

.PHONY: verify
verify: ## Run the app's R1-R17 in NS (default voting-a) and write .workflow/verify.md
	@cd app && NS="$${NS:-voting-a}" ./scripts/verify.sh

# --- Frozen checkpoints ----------------------------------------------------

.PHONY: check
check: ## Run one checkpoint from scripts/checks/: make check STEP=15
	@bash $(SCRIPTS)/checks/S$(STEP).sh
