Updated: 2026-09-16

## Working
Stage G's three steps are ticked and CLEAR, and the tick commit sits outside both reviewed ranges. What is
left is the gate's live-cluster line and the plan's Done checklist.

## Done (verified)
- S20 and S21: findings CLEAR at bfd996b, both boxes ticked in d7f2e41.
- `make targets` prints 14 names including `timeline`.
- `make check STEP=18` on the current tree: three code-shape assertions ok, then its own no-cluster
  precondition FAILs - the console's Destroy run deleted the cluster.
- On the tick-free tree, before the ticks: S20 6 ok lines + PASS, S21 8 ok lines + PASS (24 events, five
  lanes, spanning 4409s). Runs in docs/evidence/s20-retro-check.log and s21-checkpoint.log.

## Broken (confirmed by execution)
- Nothing in the code. The one FAIL is a missing precondition: no cluster means `make state` says up=false.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data directory,
  container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks fail; `ipam.py` has no lock.

## In progress
Nothing.

## Blocked
- Build-plan's Done list is open at three items: the Review section in docs/todo.md (still ends at S17),
  docs/lessons.md for the S20/S21 rework, and the production-needs note.

## Learnings
- A reviewed range must end BEFORE its step's tracker tick, so the tick is deliberately the first commit
  after the last reviewed SHA.
- A retro-checkpoint's record commit IS the reviewed diff, so it must not touch the tracker either.
