Updated: 2026-09-11

## Working
S17 is complete on the code side: every teardown exit releases its IP block exactly once, the README's
escape hatch matches the modules, and the checkpoint is green on the fixed tree. The one open item is the
independent review.

## Done (verified)
- `bash scripts/checks/S17.sh` exit 0 at c95c051: `11 PASS, 0 FAIL` then `17 PASS, 0 FAIL`
  (`docs/evidence/s17-run-postfix.log`).
- The retry-path release, proved by running it: `docs/evidence/leak-probe3.sh` + `leak-probe3-controller.log`.
- The escape hatch's variables now match `jit-modules/modules/*/variables.tf`.
- S0-S16 checkpoints pass and are committed. S00 fails by design (pre-migration assertions).

## Broken (confirmed by execution)
- Nothing known. Both defects this step opened with are fixed and re-proved.

## Suspected (read, not reproduced)
- `ipam.py` has no lock; `namespace_lock` is process-local, so a second controller replica would not
  serialise the ledger's read-modify-write.
- `_allocated_ip` returns `""` on `ApiException`, which also means "allocate" — a failed read can move a
  live claim's address and inflate the count.
- `jit-down` never reconciles `jit-ipam`, so a stack bounce can start from a stale count.
- Both exits now release only after the claim is gone, but that ordering is asserted by a probe on one
  path, not by a test that enumerates them.

## In progress
Nothing. Waiting on the independent review.

## Blocked
- The review box, on a different model writing `docs/reviews/S17-findings.md` with CLEAR.

## Learnings
- A guard that stops a second release makes one path the owner of the first; walk every other path that can
  reach that state (`docs/lessons.md`).
- A probe can pass by testing nothing: read its log against the component log before believing it.
