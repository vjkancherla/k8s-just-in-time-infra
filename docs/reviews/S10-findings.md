# S10 Review Findings (RE-REVIEW after fix commit 6d1554e)

**Step:** S10 — Soft delete: orphan and expiry
**Goal:** the last reference going away starts a clock.
**Original commit:** 1063f4d09c443dc34a1f128ce6b8d7234de0dfef
**Fix commit:** 6d1554ecc303cbfa57b445a11ef68c026ef07914 (fix(controller): address S10 review findings)
**Files:** jit-controller/main.py, deploy/controller.yaml, scripts/checks/S10.sh

## Verdict: CONCERNS (re-reviewed)

The fix commit addresses my original concerns #1 and #3, and the checkpoint passes.
Concern #2 (the `Deleting` phase) was partly implemented but its race is **not** closed,
and the fix introduces a **new** secret-in-manifest issue. Raised, not acted on.

## Checkpoint (re-run against 6d1554e)

```
deployment.apps/s10-deploy created
deployment.apps "s10-deploy" deleted from default namespace
PASS: delete last Deployment → Orphaned with expiresAt, Secret still present
deployment.apps/s10-deploy created
PASS: re-apply within window → Ready, expiry cleared, same Secret
deployment.apps "s10-deploy" deleted from default namespace
PASS: delete again, wait past TTL → Secret gone, claim gone
PASS: S10 soft delete lifecycle verified
```

Exit 0. Verified against the running controller (`jit-controller-64b7cc65dc-4vgbs`, 1/1):
`kubectl logs` shows the full sweep — `Orphaned, expiresAt=...16:49:28` → `TTL expired on
default-redis, sweeping` → `Deleted Secret jit-redis` → `Deleted claim default-redis after
TTL expiry` → `handle_claim_delete succeeded`. The new `Deleting` transition and the
guarded destroy both executed.

## What the fix changed (6d1554e vs 1063f4d)

- **Guarded destroy (concern #1 fixed).** `resync_referenced_by` now calls
  `if destroy_infra(...):` before `cleanup_k8s_resources` + `remove_finalizer_and_delete`;
  on failure it logs and leaves the claim for the next tick. `destroy_infra` also now
  sends `Authorization: Bearer {RUNNER_TOKEN}` (runner requires it — see below).
- **`Deleting` phase (concern #2, partial).** New `if phase == "Deleting":` branch
  (`main.py:281`) retries destroy+cleanup; the TTL-expiry path sets `phase="Deleting"`
  (`main.py:328`) before destroying. Matches flows.md §4.
- **Skip redundant patch (concern #3 fixed).** The Orphaned branch now computes
  `existing_refs` and only patches `if refs != existing_refs` (`main.py:303-304`).
- **`clear_status_field` (new, `main.py:154`).** Replaces the empty-string sentinel with a
  JSON Patch `op:remove`, so `expiresAt` is actually deleted from status. Used on
  resurrection (`ensure_ready` and the refs-present branch). Checkpoint Phase 2 confirms
  the field is gone.
- **S10.sh.** Phase-2 assertion simplified to `-z || == "null"` (the `== '""'` case is
  now dead since the field is removed). Line is intact.

## CONCERNS (raised, not acted on — the human should decide)

1. **Concern #2 is NOT actually fixed — resurrection during `Deleting` still possible.**
   The `Deleting` branch (`main.py:281`) lives inside the `else` of `if refs:`, so it only
   runs when `refs` is empty. The resurrection branch at `main.py:269` (`if refs:`) has no
   phase guard at all. So if a reference reappears while the claim is in `Deleting`,
   `main.py:269` fires and patches it back to `Ready` with `expiresAt` cleared — exactly
   the race this commit set out to close, and it contradicts both the documented state
   machine (flows.md §4 has no `Deleting --> Ready` edge) and the commit's own "No
   resurrection" claim. The window is the destroy+finalizer-removal period after TTL
   expiry (short in practice, but the code is inconsistent with its stated behaviour).
   Fix: guard the resurrection branch against `Deleting`, e.g. `if refs and phase !=
   "Deleting":` — or decide deliberately whether a reappearing reference should win over a
   committed destruction, and make the code match that decision. **Confident** in the read
   (the `if refs:` branch precedes and is independent of the `Deleting` check).

2. **Plaintext bearer token hardcoded in two committed manifests (NEW).**
   `deploy/controller.yaml` now sets `RUNNER_TOKEN: "s6-secret-token-2026"` and
   `jit-runner/deployment.yaml` sets `JIT_RUNNER_TOKEN: "s6-secret-token-2026"`. The runner
   validates this token (`_check_auth`, `jit-runner/main.py:64`) before any run
   operation, so anyone with read access to the repo can authenticate and destroy infra.
   This is secret-in-source-control. Should be a Kubernetes `Secret` referenced via
   `secretKeyRef`/`envFrom`, not a literal in a manifest. **Confident** the value is
   committed in both places and the runner enforces it. (Note: the new guarded destroy in
   #1 now *requires* the token to be correct for the sweep to complete, so this is wired
   in deliberately — but still hardcoded.)

## Not started

S11 not started, per instructions.
