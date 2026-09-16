Updated: 2026-09-16

## Working
Stage G's gate is met on a live cluster and the docs it owed are written: the Review section, the lessons
section and the ignore rules. What is left is the plan's Done checklist.

## Done (verified)
- S20 and S21: findings CLEAR at bfd996b, both boxes ticked in d7f2e41.
- `make targets` prints 14 names including `timeline`.
- Gate after a cold `make demo-up` ("17 PASS, 0 FAIL", "PASS: demo up - voting-a"): `make check STEP=18` gave
  12 ok lines, PASS, exit 0 - captured in docs/evidence/s18-stage-g-gate.log.
- The Review section in docs/todo.md now carries S18 (four frozen-array amendments), S19 (the cut snapshot
  mode and the vacuous assertion it left), S20 (an evidence-only diff) and S21 (the deferred live sequence).
- docs/lessons.md gained "From Stage G - two reviews blocked on a tracker tick": the tick-before-range rule,
  the record-commit rule, the amendment protocol, and S18's live-state precondition.
- On the tick-free tree, before the ticks: S20 6 ok lines + PASS, S21 8 ok lines + PASS (24 events, five
  lanes, spanning 4409s). Runs in docs/evidence/s20-retro-check.log and s21-checkpoint.log.

## Broken (confirmed by execution)
- Nothing. The one FAIL seen this session was the checkpoint's own precondition, cleared by the cold demo-up.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data directory,
  container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks fail; `ipam.py` has no lock.

## In progress
Nothing.

## Blocked
- Build-plan's Done list is open at its tracker item: docs/todo.md has 9 unticked boxes - S-1's check and
  review, and S0-S7's review - with no findings file below S08. The other three Done items now hold.

## Learnings
- A reviewed range must end BEFORE its step's tracker tick, so the tick is deliberately the first commit
  after the last reviewed SHA.
- A retro-checkpoint's record commit IS the reviewed diff, so it must not touch the tracker either.
- A checkpoint that asserts against live state cannot be re-run green on a stopped host: S18 fails on its own
  precondition until `make demo-up` has run.
