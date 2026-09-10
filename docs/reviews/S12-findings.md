# S12 Review Findings

**Step:** S12 — Controller restart resilience: a delete missed while the controller is
down is caught by the resync.
**Goal:** a delete missed while the controller is down is caught by the resync.
**Commit:** c73265c (test(controller): S12 checkpoint — controller restart resilience)
**Files:** scripts/checks/S12.sh, memory-bank/activeContext.md, memory-bank/progress.md
**Code under test:** jit-controller/main.py — **unchanged** by this step.

## Verdict: CLEAR

## Checkpoint (fresh run this session)

```
PASS: claim is Ready
PASS: controller scaled to 0
deployment.apps "s12-deploy" deleted from s12-test namespace
PASS: Deployment deleted, claim still Ready (controller was down)
PASS: controller scaled back to 1
PASS: claim is Orphaned with expiresAt after controller restart
PASS: S12 controller restart resilience verified
... cleanup: ns s12-test deleted, WATCH_NAMESPACES reset to default, rollout successful ...
```

Exit 0 (confirmed `EXIT_CODE=0` on a clean re-run).

## Why the pass is genuine (not vacuous)

- **No code change is the whole point.** `git diff --stat c73265c~1 c73265c` touches
  exactly the three files in the prompt (`S12.sh`, `activeContext.md`, `progress.md`) —
  nothing in `jit-controller/`. The checkpoint therefore exercises the *existing* resync
  path, not a new one.
- **The resync is the *only* mechanism that can fire here.** `main.py` registers
  `@kopf.on.create` / `@kopf.on.update` for Deployments (`handle_deployment`) but **no**
  `@kopf.on.delete` for Deployments. So while the controller is at 0 replicas, deleting
  the Deployment does nothing. On restart the sole re-computation path is
  `@kopf.timer(..., interval=30, initial_delay=True)` (`resync_referenced_by`,
  `main.py:255`), which calls `list_referencing_deployments()` (`main.py:264`) — a live
  `list_namespaced_deployment` filtered on `jit.infra/<module>` — and, when refs come back
  empty, transitions the claim to `Orphaned` + sets `expiresAt` (`main.py:290-301`). The
  checkpoint's `claim is Orphaned with expiresAt` assertion can therefore only pass if the
  resync caught the missed delete. That is exactly the S12 goal.
- **Negative control is solid.** Before scaling the controller back up, the checkpoint
  asserts the claim is *still* `Ready` (`main.py`-independent, line 91 of S12.sh). This
  proves the controller was genuinely down and did not observe the delete — so the later
  `Orphaned` transition is attributable to the resync, not to a fast delete handler.
- **Isolated to the soft-delete path.** The test only reaches the `Orphaned` branch; it
  never hits the `Deleting`/`destroy_infra` branch, so the unset `RUNNER_URL` (which makes
  `destroy_infra` return `False`) is irrelevant here. The S11 "hold on destroy failure"
  concern is orthogonal and out of S12's gate.

## What was reviewed

- **`resync_referenced_by`** (`main.py:255-311`). `interval=30, initial_delay=True` gives a
  30s cadence with a resync firing on startup — exactly what a restart needs. Each tick
  recomputes `referencedBy` from live Deployments and reconciles: refs present → `Ready` +
  clear `expiresAt`; refs empty, not `Deleting`, not already `Orphaned` → `Orphaned` +
  `expiresAt = now + softDeleteTTL`; refs empty and `Deleting` → retry destroy. Correct and
  sufficient for S12.
- **Checkpoint shape.** `set -euo pipefail`, `fail()` exits non-zero, `echo PASS` at the
  end, `trap cleanup EXIT`. Follows the build-plan checkpoint contract.
- **Isolation & cleanup.** Uses a dedicated `s12-test` namespace; sets
  `WATCH_NAMESPACES=default,s12-test` and rolls the controller; the `trap` removes the test
  namespace and resets `WATCH_NAMESPACES=default`. Verified live after the run: controller
  back to `1` replica, `WATCH_NAMESPACES=default`, no leftover `s12` InfraClaims.
- **Diff scope.** `git show --stat c73265c` matches the prompt's file list exactly.

## CONCERNS (raised, not acted on)

None that block or raise a real risk for this step. The one thing worth noting is that the
checkpoint mutates a **shared** deployment (`jit-controller`) env var and rolls it; that
briefly restarts the cluster-wide controller. In this PoC the only namespaces in play are
`default` and the test namespace, and the `trap` restores the prior value, so the blast
radius is contained. If this checkpoint is ever run while other namespaces hold live
claims, a concurrent restart could momentarily interrupt their resyncs — a caveat for
future maintainers, not a defect here.

## Not started

S13 (IPAM) not started, per instructions.
