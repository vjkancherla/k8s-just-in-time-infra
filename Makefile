# Makefile — root orchestration for the JIT infra PoC (build-plan S17, S18).
#
# There are two halves and they are deliberately separate:
#
#   app/        the voting app's own build/deploy/verify loop  → app/Makefile
#   here        the JIT stack: MinIO, the runner, the CRD, the controller,
#               and the J1-J11 lifecycle suite
#
# The JIT targets are thin wrappers over scripts/jit-*.sh, the same idiom as
# app/Makefile: the logic lives in a script that can be read and run on its own.

# S18 adds the surface the console drives (build-plan S18): one make target per action it
# can take, `make state` for everything it displays, and `make targets` for its buttons.
# The console runs no `kubectl` of its own - every read comes from `make state`, every
# action is one of the names `make targets` prints, and a target that is not printed
# cannot be run from the page.
#
# Every target in that allowlist appends its output to docs/evidence/<target>.log and keeps
# its exit code: `| tee` would hand make tee's status, so each recipe re-exits on
# ${PIPESTATUS[0]}. `state` and `targets` are read rather than run - their stdout *is* the
# payload the console parses - so only their stdout is logged, and nothing else may touch it.

SHELL := /bin/bash

SCRIPTS  := scripts
EVIDENCE := docs/evidence

# The demo runs in voting-a, and TENANTS is the fence around it: the two namespaces the
# console may point a target at, and the only ones `make ns-delete` will destroy.
DEMO_NS ?= voting-a
TENANTS := voting-a voting-b

# The allowlist, in the order the design's action table gives it. `make targets` prints
# exactly this list, and the console builds its buttons from that output.
CONSOLE_TARGETS := demo-up demo-undeploy demo-redeploy ns-delete test-up jit-up verify jit-verify jit-down destroy state targets

.DEFAULT_GOAL := help

.PHONY: help
help: ## List targets (this help)
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  STEP=NN     for 'make check STEP=15'"
	@echo "  NS=<ns>     for 'make verify' (default: voting-a) and 'make ns-delete'"

# --- The JIT stack ---------------------------------------------------------

.PHONY: jit-up
jit-up: ## Boot the out-of-cluster half: MinIO, runner, CRD, controller
	@mkdir -p $(EVIDENCE)
	@./$(SCRIPTS)/jit-up.sh 2>&1 | tee -a $(EVIDENCE)/jit-up.log; exit $${PIPESTATUS[0]}

.PHONY: jit-verify
jit-verify: ## Run the J1-J11 lifecycle suite -> .workflow/verify-jit.md (non-zero on FAIL)
	@mkdir -p $(EVIDENCE)
	@./$(SCRIPTS)/verify-jit.sh 2>&1 | tee -a $(EVIDENCE)/jit-verify.log; exit $${PIPESTATUS[0]}

.PHONY: jit-down
jit-down: ## Remove the controller, the runner, MinIO and any leftover JIT containers
	@mkdir -p $(EVIDENCE)
	@./$(SCRIPTS)/jit-down.sh 2>&1 | tee -a $(EVIDENCE)/jit-down.log; exit $${PIPESTATUS[0]}

# Destroy is the console's one button that takes the whole stack: the plane first, because the
# module containers and volumes outlive the cluster, then the cluster itself.

.PHONY: destroy
destroy: ## Everything: the JIT plane first, then the k3d cluster and the secret file
	@mkdir -p $(EVIDENCE)
	@{ ./$(SCRIPTS)/jit-down.sh && ( cd app && make destroy ); } 2>&1 | tee -a $(EVIDENCE)/destroy.log; exit $${PIPESTATUS[0]}

# --- The app ---------------------------------------------------------------

.PHONY: verify
verify: ## Run the app's R1-R17 in NS (default voting-a) and exit non-zero if any FAILs
	@mkdir -p $(EVIDENCE)
	@rm -f app/.workflow/verify.md
	@( cd app && NS="$${NS:-voting-a}" ./scripts/verify.sh ) 2>&1 | tee -a $(EVIDENCE)/verify.log; exit $${PIPESTATUS[0]}
	@summary="$$(grep -E '^===== [0-9]+ PASS, [0-9]+ FAIL =====$$' app/.workflow/verify.md | tail -1)"; printf '%s\n' "$$summary"; case "$$summary" in *', 0 FAIL'*) ;; *) echo "FAIL: the R-checks did not all pass - see app/.workflow/verify.md" >&2; exit 1;; esac

# --- The demo --------------------------------------------------------------
# demo-up and test-up are the cold path docs/evidence/s17-cold-path-green.log established,
# run by scripts/demo-up.sh for one namespace or both. Neither is a second cold path: both
# call the targets S17 left green.

.PHONY: demo-up
demo-up: ## Demo · Start the demo: jit-down, deploy, jit-up, then deploy + verify voting-a
	@mkdir -p $(EVIDENCE)
	@./$(SCRIPTS)/demo-up.sh $(DEMO_NS) 2>&1 | tee -a $(EVIDENCE)/demo-up.log; exit $${PIPESTATUS[0]}

.PHONY: demo-undeploy
demo-undeploy: ## Demo · Delete the vote Deployment; the containers keep running on a clock
	@mkdir -p $(EVIDENCE)
	@kubectl delete deployment voting-app-vote -n $(DEMO_NS) --ignore-not-found 2>&1 | tee -a $(EVIDENCE)/demo-undeploy.log; exit $${PIPESTATUS[0]}

.PHONY: demo-redeploy
demo-redeploy: ## Demo · Re-apply the overlay inside the window; the claim returns to Ready
	@mkdir -p $(EVIDENCE)
	@kubectl apply -k app/kustomize/overlays/$(DEMO_NS) 2>&1 | tee -a $(EVIDENCE)/demo-redeploy.log; exit $${PIPESTATUS[0]}

.PHONY: ns-delete
ns-delete: ## Demo · Destroy NS now, ignoring the retention clock; only NS=(voting-a|voting-b)
	@if [ -z "$(NS)" ]; then echo "FAIL: ns-delete needs NS=<namespace>, one of: $(TENANTS)" >&2; exit 1; fi
	@case " $(TENANTS) " in *" $(NS) "*) ;; *) echo "FAIL: ns-delete refuses NS=$(NS) - it destroys only: $(TENANTS)" >&2; exit 1;; esac
	@mkdir -p $(EVIDENCE)
	@kubectl delete namespace $(NS) --timeout=300s 2>&1 | tee -a $(EVIDENCE)/ns-delete.log; exit $${PIPESTATUS[0]}

.PHONY: test-up
test-up: ## Testing · Set everything up: both namespaces, deployed and verified
	@mkdir -p $(EVIDENCE)
	@./$(SCRIPTS)/demo-up.sh $(TENANTS) 2>&1 | tee -a $(EVIDENCE)/test-up.log; exit $${PIPESTATUS[0]}

# --- The console's read model and its allowlist ----------------------------

.PHONY: state
state: ## Print the read model: one JSON object, from kubectl, the ledger, docker, MinIO
	@mkdir -p $(EVIDENCE)
	@./$(SCRIPTS)/state.sh | tee -a $(EVIDENCE)/state.log; exit $${PIPESTATUS[0]}

.PHONY: targets
targets: ## Print the console's allowlist, one target per line (its buttons come from this)
	@mkdir -p $(EVIDENCE)
	@printf '%s\n' $(CONSOLE_TARGETS) | tee -a $(EVIDENCE)/targets.log; exit $${PIPESTATUS[0]}

# --- Frozen checkpoints ----------------------------------------------------

.PHONY: check
check: ## Run one checkpoint from scripts/checks/: make check STEP=15
	@bash $(SCRIPTS)/checks/S$(STEP).sh
