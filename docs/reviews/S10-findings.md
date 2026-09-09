# S10 Review Findings (FINAL — CLEAR after fix commits 6d1554e + 3fc885f)

**Step:** S10 — Soft delete: orphan and expiry
**Goal:** the last reference going away starts a clock.
**Original commit:** 1063f4d09c443dc34a1f128ce6b8d7234de0dfef
**Fix commits:**
- 6d1554e — fix(controller): address S10 review findings (guarded destroy, Deleting phase, skip redundant patch)
- 3fc885f — fix(controller): address S10 re-review findings (resurrection guard, secretKeyRef)
**Files:** jit-controller/main.py, deploy/controller.yaml, scripts/checks/S10.sh

## Verdict: CLEAR

All three original concerns are fixed. The checkpoint passes (re-run against each fix
commit). The code now matches the documented state machine (flows.md §4) with no open
robustness or correctness gaps.

## Checkpoint (re-run against 3fc885f)

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

Exit 0. Verified against running controller (`jit-controller-7c6cbddf69-jmprh`, 1/1);
MD5 of `/app/main.py` matches local `jit-controller/main.py` (`4a43382d`).
`kubectl logs` confirms the full sweep: `referencedBy=['s10-deploy'], phase=Ready` →
`Orphaned, expiresAt=2026-09-09T09:27:45` → `TTL expired on default-redis, sweeping` →
`Deleted claim default-redis after TTL expiry`. The Deleting transition and guarded
destroy executed end-to-end. `RUNNER_TOKEN` sourced correctly from `secretKeyRef`
(`jit-runner-token` Secret verified present).

## What changed across the two fix commits

**6d1554e** (first fix):
- Guarded destroy: `if destroy_infra(...):` now gates `cleanup_k8s_resources` +
  `remove_finalizer_and_delete`; on failure, claim stays and retries next tick. Fixes
  the infra-leak path (original concern #1).
- `Deleting` phase added: TTL-expiry sets `phase="Deleting"` before destroying; a new
  `if phase == "Deleting":` branch retries destroy on subsequent ticks. Matches flows.md
  §4 (original concern #2, partial).
- Skip redundant patch: Orphaned branch now change-detects `refs != existing_refs`
  before patching (original concern #3).
- `clear_status_field` using JSON Patch `op:remove` (replaces empty-string sentinel).
- `RUNNER_TOKEN` wired into `destroy_infra` with Bearer auth (runner requires it).

**3fc885f** (second fix, from re-review):
- Resurrection guard: line 269 changed from `if refs:` to `if refs and phase !=
  "Deleting":`. References reappearing during the Deleting phase no longer resurrect the
  claim. This is the key change that closes the race flagged in the re-review and makes
  the code match flows.md §4 (no `Deleting --> Ready` edge).
- `secretKeyRef`: `deploy/controller.yaml` now sources `RUNNER_TOKEN` from a Kubernetes
  Secret (`jit-runner-token`, key `token`) via `valueFrom.secretKeyRef` instead of a
  hardcoded literal in the pod spec. The Secret itself is bootstrapped via `stringData` in
  the same manifest — standard PoC pattern; in production the Secret would be managed
  separately.

## Assessment of each original concern

1. **Leak on destroy failure (original concern #1): FIXED.** `destroy_infra` return now
   gates all three cleanup calls. On failure, claim stays in `Deleting` and retries every
   30s tick. `RUNNER_TOKEN` is correctly sourced via `secretKeyRef` and validated by the
   runner (`_check_auth`, `jit-runner/main.py:64`).

2. **Deleting phase / resurrection race (original concern #2): FIXED.** The `Deleting`
   phase exists with a retry branch, AND the resurrection branch respects it. A reference
   reappearing during `Deleting` is now a no-op (`refs` is non-empty but `phase ==
   "Deleting"` → `if refs and phase != "Deleting":` is False → falls into `else` →
   `phase == "Deleting"` → retries destroy). Consistent with flows.md §4.

3. **Redundant status patch (original concern #3): FIXED.** Orphaned branch skips the
   patch when `refs == existing_refs`. No more no-op watch events per orphaned claim.

## Not started

S11 not started, per instructions.
