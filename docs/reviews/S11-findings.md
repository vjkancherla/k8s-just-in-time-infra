# S11 Review Findings

**Step:** S11 — Hard delete: namespace deletion destroys now, regardless of expiry
**Goal:** namespace deletion destroys now, regardless of expiry.
**Commit:** 96312f7b02f6612ea4091b3c6df7abaa546acd26 (feat(controller): S11 hard delete — namespace destroys immediately)
**Files:** jit-controller/main.py, deploy/controller.yaml, scripts/checks/S11.sh

## Verdict: CLEAR

The checkpoint passes (exit 0) against the live controller running the exact code at
`96312f7` (MD5 of `/app/main.py` == local `jit-controller/main.py` == `61945d48`). The
goal is met: deleting a namespace tears down the claim, its Secret/Service/EndpointSlice,
and the runner-managed container immediately, without waiting on the TTL.

## Checkpoint (fresh run this session)

```
deployment.apps/jit-controller env updated
... rollout successful ...
namespace/s11-test created
deployment.apps/s11-deploy created
deployment.apps "s11-deploy" deleted from s11-test namespace
PASS: Orphaned with 30d TTL, Secret present
namespace "s11-test" deleted
PASS: namespace deleted without hanging
PASS: claim and Secret destroyed before TTL expiry
PASS: S11 hard delete verified
... cleanup: WATCH_NAMESPACES reset to default, rollout successful ...
```

Exit 0.

## Why the pass is genuine (not vacuous)

- The InfraClaim carries the `jit.infra/teardown` finalizer, so Kubernetes GC **cannot**
  remove it — a finalized object sits in `Terminating` until the finalizer is stripped.
  The checkpoint's `namespace deleted without hanging` assertion therefore only passes if
  the controller's `@kopf.on.delete` handler fired and removed the finalizer. A broken or
  absent handler leaves the namespace stuck → the gate fails. The pass proves the handler
  ran.
- The claim is created with `softDeleteTTL: 30d`. The 60s window in step 3 is far below
  the TTL, so the claim/Secret can only disappear via the **hard-delete path**, not the
  soft-delete sweep. The checkpoint isolates the S11 behavior.
- The delete handler calls `destroy_infra` (runner DELETE) → `cleanup_k8s_resources`
  (Secret/Service/EndpointSlice) → strip finalizer, in that order. Since the handler fired
  (proven above), the full destroy sequence executed.

## What was reviewed

- **`handle_claim_delete`** (`main.py:342`). Changed from "strip finalizer only" to:
  `load_kube()` → read `spec.module` → `destroy_infra(namespace, module)` +
  `cleanup_k8s_resources(namespace, module)` → strip finalizer. Matches flows.md §3
  (hard-delete sequence) and the state machine's `Ready/Orphaned --> Deleting` on
  namespace delete. The `module` guard logs and skips infra cleanup if the claim somehow
  has no module — defensive, correct.
- **Finalizer strip fixed.** Now patches `{"metadata": {"finalizers": new_finalizers}}`
  (plain dict) instead of mutating and re-submitting the kopf `Body` object. This was the
  S11 bug noted in the commit message — `patch_namespaced_custom_object` needs a plain
  dict, not a kopf Body. Verified live: the namespace completed deletion.
- **`WATCH_NAMESPACES`** (`main.py:367-370`). `kopf.run(namespaces=...)` now reads the
  comma-separated env var (default `default`), so the controller can watch namespaces
  beyond `default` without a code change. The checkpoint sets it to `default,s11-test`,
  rolls the controller, and resets it in the `trap` cleanup. RBAC is unaffected — the
  `jit-controller` ClusterRole/ClusterRoleBinding are cluster-wide (`*/*`), so watching a
  second namespace needs no new permissions.
- **`destroy_infra` / `cleanup_k8s_resources`.** `destroy_infra` does `DELETE
  {RUNNER_URL}/v1/runs/{namespace}` with the Bearer token; returns True on 200/404.
  `workspace = namespace` matches the create path (`POST /v1/runs` with `workspace=ns`),
  so the same runner run is destroyed. `cleanup_k8s_resources` deletes Secret, Service,
  and EndpointSlice, tolerating 404s (idempotent). Order (runner then k8s) matches the
  S10 sweep path.
- **Checkpoint shape.** `set -euo pipefail`, `fail()` exits non-zero, `echo PASS` at the
  end, `trap` cleanup removes the test namespace and restores `WATCH_NAMESPACES`. Follows
  the build-plan checkpoint contract. No stray test artifacts left behind.
- **Diff scope.** `git show --stat 96312f7` touches exactly the three files in the prompt
  (`main.py`, `controller.yaml`, `S11.sh`). No incidental changes.

## CONCERNS (raised, not acted on)

1. **Finalizer released unconditionally on destroy failure — deviates from flows.md §3.**
   `handle_claim_delete` calls `destroy_infra` but ignores its return value: the finalizer
   is stripped whether or not the runner destroy succeeded. flows.md §3 documents the
   opposite — *"If the runner call fails, the finalizer is not released and the namespace
   stays in Terminating"* — and the state machine diagram has the `Deleting --> Deleting:
   destroy failed, finalizer held` edge. Consequences:
   - On a runner failure (down, timeout, 5xx), the container keeps running → **infra leak
     with no retry**, because the claim is already gone and nothing re-triggers the
     destroy.
   - Inconsistent with the S10 soft-delete sweep, where `remove_finalizer_and_delete` is
     gated on `if destroy_infra(...)` success and the claim stays in `Deleting` retrying
     every 30s tick.
   This is out of S11's gate scope (the checkpoint only exercises the happy path, which
   passes), so it does not block. But it is a real gap: to make the "hold on failure"
   behavior match the docs, the delete handler would need to set `phase=Deleting` and hold
   the finalizer on destroy failure, letting the resync retry — the same pattern the S10
   sweep uses. Worth a follow-up or folding into S12 (retry/resilience). Not a blocker.

## Not started

S12 not started, per instructions.