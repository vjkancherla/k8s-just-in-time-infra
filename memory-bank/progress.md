Updated: 2026-09-11

## Working
S17 is reviewed, its concerns are fixed or flagged, the demo namespace convention is pinned in code, and the
demo runs again. One cold-start blocker is open, and it is a design question.

## Done (verified)
- Checkpoint at c95c051: `11 PASS, 0 FAIL` then `17 PASS, 0 FAIL` (`docs/evidence/s17-run-postfix.log`);
  `make verify` re-run green after every later change.
- `jit-down` clears the IPAM ledger and waits for its claims; the bounce is green (`s17-jitdown-bounce.log`).
- The R-checks no longer abort on an empty `OPTS` or let R5 pass vacuously
  (`s17-rchecks-negative-options.log`: 10 PASS, 7 FAIL with honest reasons).
- Cold-start traps: `jit-up` imports the controller image; `jit-down` survives no CRD; a bare `make all`
  deploys to `voting-a`.
- Demo healthy: three claims Ready, ledger `{"voting-a": {"offset": 0, "count": 3}}`, three pods 1/1.

## Broken (confirmed by execution)
- **A cold start cannot bring the app up**: `init-db` gets
  `FATAL: password authentication failed for user "postgres"` because the postgres volume outlives its
  container while the controller regenerates the password (`docs/evidence/s17-cold-path.log`).

## Suspected (read, not reproduced)
- `ipam.py` has no lock of its own; `namespace_lock` is process-local.
- `_allocated_ip` returns `""` on `ApiException`, which also means "allocate".
- A claim can be `Ready` with no container behind it; the stale-Ready check only looks for the Secret.

## In progress
Nothing. Waiting on the volume-vs-password decision.

## Blocked
- The cold-start Done item (design question above) and the review box (the human's tick).

## Learnings
- Run the failure path: the cold start found four defects, one of them in the fix made the same day.
- Two stores of one image, two homes for one app, one volume outliving its password - the expensive bugs
  here are all "the same thing in two places".
- Read the comments before spending a cluster: two of the four contradictions were already written down.
