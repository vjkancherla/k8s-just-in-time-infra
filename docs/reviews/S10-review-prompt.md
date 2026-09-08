# S10 Review Prompt

**Step:** S10
**Goal:** the last reference going away starts a clock.

**Commit range:** 1063f4d

**Files changed:**
- jit-controller/main.py
- jit-controller/Dockerfile
- jit-controller/requirements.txt
- deploy/controller.yaml
- scripts/checks/S10.sh

**Checkpoint to run:** `bash scripts/checks/S10.sh`

**Instructions:**
1. Read docs/build-plan.md S10, docs/jit-infra-flows.md §2 (soft delete), §4 (state machine), §5 (resync loop)
2. Review the timer handler's state machine: Ready↔Orphaned transitions, TTL parsing, sweep logic
3. Review cleanup: destroy_infra, cleanup_k8s_resources, remove_finalizer_and_delete
4. Review the expiresAt clearing on resurrection (ensure_ready and timer)
5. Review checkpoint script for correctness and edge cases
6. Run checkpoint
7. Write docs/reviews/S10-findings.md with CLEAR / BLOCKED / CONCERNS

Do not start S11.