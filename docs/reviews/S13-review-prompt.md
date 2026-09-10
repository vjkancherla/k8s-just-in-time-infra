# S13 Review Prompt

**Step:** S13
**Goal:** deterministic addresses per namespace.

**Commit range:** 7ef9931

**Files changed:**
- jit-controller/ipam.py (new)
- jit-controller/test_ipam.py (new)
- jit-controller/main.py (modified)
- jit-controller/Dockerfile (modified)
- deploy/crd/infraclaim.yaml (modified)
- scripts/checks/S13.sh (new)

**Checkpoint to run:** `bash scripts/checks/S13.sh`

**Instructions:**
1. Read docs/build-plan.md S13
2. Review jit-controller/ipam.py: ConfigMap-backed IPAM allocating blocks of 10 from 172.19.0.100-199. allocate_block() is idempotent (returns existing block). release_block() decrements count and frees block when count hits 0.
3. Review jit-controller/main.py changes: allocate_block called in ensure_claim, allocatedIP set in claim status. release_block called in resync sweep (after remove_finalizer_and_delete) and handle_claim_delete (after finalizer removal).
4. Review deploy/crd/infraclaim.yaml: allocatedIP field added to status schema
5. Review unit tests: _base_ip and _free_offsets pure logic (9 tests, no kubernetes dependency)
6. Review checkpoint script: Phase 1 — two namespaces get non-overlapping blocks. Phase 2 — delete Deployment, orphan, TTL sweep frees block. Phase 3 — re-create gets a new block.
7. Note: release_block is called AFTER finalizer removal in handle_claim_delete to prevent handler failure from blocking the claim deletion
8. Write docs/reviews/S13-findings.md with CLEAR / BLOCKED / CONCERNS

Do not start S14.