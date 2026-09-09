# S13 Review Findings

**Step:** S13 — IPAM: deterministic IP blocks per namespace.
**Goal:** deterministic addresses per namespace.
**Commit:** 7ef9931 (feat(controller): S13 IPAM - allocate/release IP blocks per namespace)
**Files:** jit-controller/ipam.py (new), jit-controller/test_ipam.py (new),
jit-controller/main.py (modified), jit-controller/Dockerfile (modified),
deploy/crd/infraclaim.yaml (modified), scripts/checks/S13.sh (new)
**Code under test:** jit-controller/ipam.py (new), jit-controller/main.py (S13 hunks)

## Verdict: CLEAR (pending human tick)

Re-reviewed after the implementer addressed both earlier CONCERNS (commit `fd001ba`).
Both fixes verified below. Per protocol the human ticks the review box; this CLEAR means
the concerns are closed and the step's evidence holds.

## Checkpoint (fresh run this session)

```
PASS: two namespaces have non-overlapping blocks (172.19.0.100, 172.19.0.110)
PASS: claim is Orphaned after deleting Deployment
PASS: last claim destroyed freed its block; other namespace untouched
PASS: re-created claim got block 172.19.0.100
PASS: S13 IPAM verified
```

Exit 0. Unit tests: `python3 -m pytest jit-controller/test_ipam.py` → **19 passed**
(9 original + 10 new for the allocate/release state machine).

## Why the pass is genuine (not vacuous)

- **Live cluster, real controller.** The checkpoint sets `WATCH_NAMESPACES=default,s13-a,s13-b`
  on the running `jit-controller` deployment, rolls it, and drives real InfraClaims through
  the create → allocated → orphan → TTL-sweep → destroy → release lifecycle. The assertions
  read the actual `jit-ipam` ConfigMap and the claims' `status.allocatedIP`, so the pass
  proves end-to-end allocation/release, not a stubbed path.
- **Non-overlap is the real check.** `172.19.0.100 != 172.19.0.110` and both octets are in
  `[100,190]` — this only holds if `allocate_block` handed each namespace a distinct free
  offset. Phase 2 then proves release (block A gone, block B untouched) and Phase 3 proves
  re-allocation. The three phases map 1:1 to the build-plan's checkpoint contract.
- **`allocatedIP` is wired.** Phase 1 asserts `status.allocatedIP == block.base_ip` for both
  claims, confirming the `main.py` status patch and the CRD schema addition both land.

## CONCERNS (raised, not acted on)

### 1. `allocate_block` never increments `count`, so the block is freed on the *first*
### release, not when the *last* claim goes.

**ADDRESSED in fd001ba.** `allocate_block` now increments `count` on every call — both the
fresh-allocation path (`count: 1`) and the idempotent path (`count += 1`). A namespace
with N claims will have `count == N`, and the block is freed only on the Nth `release_block`
call. Unit test `test_two_claims_one_namespace` exercises this exact sequence.

### 2. Unit tests cover `_base_ip`/`_free_offsets` but not the `allocate_block`/
### `release_block` state machine.

**ADDRESSED in fd001ba.** Added 10 unit tests across `TestAllocateBlock` (6 tests),
`TestReleaseBlock` (3 tests), and `TestAllocateReleaseLifecycle` (1 test). All mock
`_read_allocations`/`_write_allocations` to isolate the k8s boundary. The lifecycle test
specifically covers the two-claims-one-namespace sequence that would have caught Concern 1.
Total: 19 tests, all passing.

Both concerns shared one root: the count-management logic was untested and wrong vs. the
design intent. **Both resolved in fd001ba**: the count logic is corrected and the test suite
now covers the full allocate/release state machine. Checkpoint re-run confirms no regression.


## What was reviewed (and found correct)

- **`allocate_block` idempotency.** Returns the existing block without re-writing when the
  namespace already holds one — correct, and it prevents a rewrite storm on repeated
  `ensure_claim` calls.
- **`release_block` no-op guard.** `if namespace not in allocations: return` makes a second
  release safe. Since `handle_claim_delete` and `resync_referenced_by` are mutually exclusive
  deletion paths for a single claim, there is no realistic double-release; and even if one
  occurred, the guard neutralises it.
- **Finalizer ordering.** `handle_claim_delete` calls `release_block` **after**
  `remove_finalizer_and_delete` (`main.py:378`); `resync_referenced_by` calls it after
  `remove_finalizer_and_delete` (`main.py:346`). If `release_block` throws, the finalizer
  is already gone, so the claim is not wedged by `KopfFinalizerMarker`. Matches the prompt's
  note and the S11 learning in the memory bank.
- **`ensure_claim` status patch.** Wrapped in `try/except ApiException` (best-effort; a
  failed status patch does not abort allocation). Allocated block is captured before the
  patch, so allocation and status stay consistent.
- **CRD schema.** `allocatedIP: type: string` added to `status`; matches the value written.
- **Dockerfile.** `COPY main.py ipam.py ./` — `ipam.py` is now importable by `main.py`
  (`from ipam import ...`). Correct; without it the import would fail at runtime.
- **Checkpoint shape.** `set -euo pipefail`, `fail()` exits non-zero, `trap cleanup EXIT`,
  dedicated `s13-a`/`s13-b` namespaces, `WATCH_NAMESPACES` restored to `default` on cleanup.
  Verified live after the run: controller rolled back, no leftover `s13-*` namespaces or
  InfraClaims.

## Minor notes (low risk, no action required)

- **Read-modify-write race.** `allocate_block`/`release_block` read the ConfigMap, mutate,
  then patch with no `resourceVersion` optimistic-lock. Under a single controller this is
  unlikely to collide; a concurrent writer on a transient read-failure (`_read_allocations`
  returns `{}` on any exception) could hand out a duplicate offset. Low risk for this PoC;
  note for whoever hardens IPAM.

## Not started

S14 (real provisioning via the runner) not started, per instructions.
