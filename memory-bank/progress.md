Updated: 2026-09-11

## Working
S17's code is complete, reviewed (CONCERNS, no blockers) and hardened by exercising its failure paths:
the stack bounce and the R-checks' diagnostics both behave as documented now.

## Done (verified)
- Checkpoint at c95c051: `11 PASS, 0 FAIL` then `17 PASS, 0 FAIL`; `make verify` re-run green (17 PASS)
  after every later change (`docs/evidence/s17-run-postfix.log`).
- Bounce: `docs/evidence/s17-jitdown-bounce.log` — ledger absent after `jit-down`, no leftover claims
  after `jit-up`, three claims and the rebuilt ledger after a Deployment touch, 17 PASS.
- R-checks against a dead app: `10 PASS, 7 FAIL`, each failure its own reason, no `unbound variable`
  noise (`docs/evidence/s17-rchecks-negative-options.log`).
- The teardown leak and its fix: `leak-probe2.*`, `leak-probe3.*`.
- S0-S16 checkpoints pass and are committed. S00 fails by design (pre-migration assertions).

## Broken (confirmed by execution)
- Nothing known. Every defect S17 found, and every one its review or the bounce found, is fixed and
  re-proved.

## Suspected (read, not reproduced)
- The cold path: `make destroy` removes the cluster and `jit-controller:latest` with it, and `jit-up.sh`
  does not import it. Not run — it deletes the cluster.
- `ipam.py` has no lock of its own; `_allocated_ip` returns `""` on `ApiException`, which also means
  "allocate".
- `var.share_dir` defaults to `/tmp`, correct only when tofu runs on the Docker daemon's host.

## In progress
Nothing. The next move is the human's: the review box, or the cold-path run.

## Blocked
- The review box (the human's tick) and the cold-path run (their call; it deletes the cluster).

## Learnings
- Run the failure path, not only the happy one: the second bounce found a `jit-down` race and an
  unguarded `OPTS` that every green run had hidden.
- `--wait=false` next to a stateful consumer of the deleted object is a race worth writing down.
