# S09 Review Findings

**Step:** S9 — Resync computes `referencedBy`
**Goal:** the controller derives references rather than trusting events.
**Commit:** 5d0281304e4ee0af00b2eb37c62e1d0b7bb86e9c (feat(controller): S9 resync computes referencedBy from live Deployments)
**Files:** jit-controller/main.py, scripts/checks/S09.sh

## Verdict: CLEAR

## Checkpoint

```
deployment.apps/s9-test-deploy-a created
deployment.apps/s9-test-deploy-b created
deployment.apps "s9-test-deploy-b" deleted from default namespace
PASS: resync computes referencedBy from live Deployments
deployment.apps "s9-test-deploy-a" deleted from default namespace
```

Exit 0. The pass is genuine: `jit-controller` is running 1/1 in `default` (verified
`kubectl get deploy -A`), the `infraclaims.jit.io` CRD is installed, and the claim
`default-redis` exists from S8. The checkpoint drove a real create → resync → delete →
resync cycle and asserted the derived state each time.

The gate is real, not vacuous:
- `phase==Ready` is checked before and after (the S8 patch set it Ready; a broken
  controller would leave it empty and fail here).
- `referencedBy` must contain **both** deploy names on pass 1, then **only** `A` after
  `B` is deleted on pass 2 — the `grep` patterns are distinct (`s9-test-deploy-a` vs
  `s9-test-deploy-b`, no prefix overlap), so no false match.
- The delete is reflected only on the *next* 30s tick, not instantly — which is the
  point. The test proves the reference set is **derived** on each pass, not propagated
  from a delete event.

Confirmed independently after the checkpoint: both test Deploys were removed by the
`trap` cleanup, and the live claim now reads `referencedBy=[]`, `phase=Ready` — the
resync recomputed the empty set from live Deployments and did not orphan (orphaning is
S10). That is the S9 behaviour in one snapshot.

## What was reviewed

- **Design alignment.** build-plan S9: "periodic resync (30s). For each claim, list
  live Deployments in the namespace that annotate that module. Write the list to
  `status.referencedBy`. Do not implement orphaning yet." The implementation matches
  this exactly. The design note ("How the controller knows a Deployment is gone") and
  flows.md §5 describe the same derivation; this step implements the first half
  (compute the reference set) and defers the second half (phase transitions) to S10,
  which is the intended scope.
- **`list_referencing_deployments`** (`main.py:144`): `AppsV1Api().list_namespaced_deployment`,
  keeps deployments whose `metadata.annotations` contain `jit.infra/{module}`, returns
  `sorted(refs)`. Correct — a straight live list, no cached/incremental state to drift.
- **`resync_referenced_by`** (`main.py:156`): `@kopf.timer(..., interval=30,
  initial_delay=True)` on the InfraClaim CRD, so kopf invokes it once per claim. Reads
  `module` from `body.spec.module` (early return if absent), calls the helper, patches
  `status.referencedBy`, catches `ApiException` and logs a warning (next tick retries —
  acceptable for a resync). The `initial_delay=True` gives an immediate first tick, so
  the checkpoint does not wait a full 30s before the first observation.
- **Idempotence / no counter.** The reference set is recomputed from scratch each tick,
  so refcounting needs no counter to get out of sync (design note: "derived state
  cannot drift"). Two Deploys → one claim with two refs; delete one → one ref. Exactly
  the last-reference rule, without implementing it.
- **Checkpoint shape.** `set -euo pipefail`, `fail()` exits non-zero, `echo PASS` at
  the end, `trap` cleanup removes test Deploys. Follows the build-plan checkpoint
  contract (non-zero on failure). The `grep ... || echo ""` guard prevents an empty
  jsonpath from aborting the loop under `-e`.
- **Diff scope.** `git show --stat 5d02813` touches exactly `jit-controller/main.py`
  (+31) and `scripts/checks/S09.sh` (+159), 190 insertions. No stray changes, matches
  the prompt.

## CONCERNS (raised, not acted on — out of S9 scope)

1. **No delete-watch fast path.** The design note (§5, flows.md) says "The delete watch
   still exists so the common case is fast; the resync is what makes it correct." The
   S9 controller has no `@kopf.on.delete("apps", "Deployment")` handler — a deleted
   Deployment is detected only on the next 30s resync tick. This is **consistent with the
   S9 build-plan** (which requires only the resync) and does **not** affect correctness
   — the resync makes it correct, and the checkpoint's tick-delay is itself the proof of
   derivation. It is a latency trade-off (up to 30s to notice a delete), not a
   correctness gap. Not a blocker; flagging so it is a conscious choice rather than an
   accidental omission before S10 wires in phase transitions.

2. **Status re-patched every tick.** `resync_referenced_by` calls
   `patch_namespaced_custom_object_status` on every 30s pass even when `referencedBy`
   is unchanged, emitting a watch event per claim every 30s. Purely an efficiency matter
   (a change-detection guard would drop no-op patches); not a correctness issue and
   irrelevant to the S9 checkpoint.

Neither concern blocks the step. The checkpoint gates the S9 property — derived
references, no orphaning — and it holds.

## Not started

S10 not started, per instructions.