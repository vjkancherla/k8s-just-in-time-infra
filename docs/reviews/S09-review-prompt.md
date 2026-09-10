# S09 Review Prompt

**Step:** S9
**Goal:** the controller derives references rather than trusting events.

**Commit range:** 5d02813

**Files changed:**
- jit-controller/main.py
- scripts/checks/S09.sh

**Checkpoint to run:** `scripts/checks/S09.sh`

**Instructions:**
1. Read docs/build-plan.md S9, docs/jit-infra-poc.md "How the controller knows a Deployment is gone"
2. Read also docs/jit-infra-flows.md §5 (resync loop) and §4 (state machine)
3. Review controller resync logic, referencedBy computation, checkpoint script
4. Run checkpoint
5. Write docs/reviews/S09-findings.md with CLEAR / BLOCKED / CONCERNS

Do not start S10.