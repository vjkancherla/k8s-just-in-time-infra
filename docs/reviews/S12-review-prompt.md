# S12 Review Prompt

**Step:** S12
**Goal:** a delete missed while the controller is down is caught by the resync.

**Commit range:** c73265c

**Files changed:**
- scripts/checks/S12.sh (new)
- memory-bank/activeContext.md
- memory-bank/progress.md

**Checkpoint to run:** `bash scripts/checks/S12.sh`

**Instructions:**
1. Read docs/build-plan.md S12
2. Confirm no code changes to jit-controller/main.py were needed — the existing @kopf.timer resync (30s, initial_delay=True) already recomputes referencedBy from live Deployments on each tick
3. Review checkpoint script: scale controller to 0 → delete Deployment → scale back to 1 → claim becomes Orphaned within resync interval
4. Verify the test uses a dedicated namespace (s12-test) with WATCH_NAMESPACES and proper cleanup
5. Run checkpoint
6. Write docs/reviews/S12-findings.md with CLEAR / BLOCKED / CONCERNS

Do not start S13.
