# S11 Review Prompt

**Step:** S11
**Goal:** namespace deletion destroys now, regardless of expiry.

**Commit range:** 96312f7

**Files changed:**
- jit-controller/main.py
- deploy/controller.yaml
- scripts/checks/S11.sh

**Checkpoint to run:** `bash scripts/checks/S11.sh`

**Instructions:**
1. Read docs/build-plan.md S11, docs/jit-infra-flows.md §3 (hard delete)
2. Review handle_claim_delete: calls destroy_infra + cleanup_k8s_resources before stripping finalizer
3. Review WATCH_NAMESPACES env var making namespace list configurable
4. Review checkpoint script: namespace creation, Orphaned with 30d TTL, namespace delete, claim+Secret gone
5. Run checkpoint
6. Write docs/reviews/S11-findings.md with CLEAR / BLOCKED / CONCERNS

Do not start S12.