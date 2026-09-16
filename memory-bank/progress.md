Updated: 2026-09-16

## Working
Stage G's gate is met on a live cluster, the docs it owed are written, and the build-plan Done list is closed
with nine boxes left unticked and explained in docs/todo.md.

## Done (verified)
- S20 and S21: findings CLEAR at bfd996b, both boxes ticked in d7f2e41.
- `make targets` prints 14 names including `timeline`.
- Gate after a cold `make demo-up` ("17 PASS, 0 FAIL", "PASS: demo up - voting-a"): `make check STEP=18` gave
  12 ok lines, PASS, exit 0 - captured in docs/evidence/s18-stage-g-gate.log.
- The Review section in docs/todo.md now carries S18 (four frozen-array amendments), S19 (the cut snapshot
  mode and the vacuous assertion it left), S20 (an evidence-only diff) and S21 (the deferred live sequence).
- docs/lessons.md gained "From Stage G - two reviews blocked on a tracker tick": the tick-before-range rule,
  the record-commit rule, the amendment protocol, and S18's live-state precondition.
- docs/todo.md gained "The boxes", saying why S-1's check and S0-S7's reviews stay unticked, and build-plan's
  four Done items are ticked with their evidence.
- On the tick-free tree: S20 6 ok + PASS, S21 8 ok + PASS (24 events, 4409s) - s20-retro-check.log, s21-checkpoint.log.
- `make timeline` against this session's stack: up, 36 events, five lanes, all thirteen kinds (2eb5073).
- docs/timeline.html draws such a run: five lanes, run picker, ?win=1 sub-second zoom, ?filter= - headless-Chrome verified.

## Broken (confirmed by execution)
- Nothing. The one FAIL seen this session was the checkpoint's own precondition, cleared by the cold demo-up.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data directory,
  container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks fail; `ipam.py` has no lock.

## In progress
Nothing.

## Blocked
- Nothing blocks work. S22 (live lanes) is unwritten future work, not a blocker.

## Learnings
- A reviewed range must end BEFORE its step's tracker tick, so the tick is deliberately the first commit
  after the last reviewed SHA.
- A retro-checkpoint's record commit IS the reviewed diff, so it must not touch the tracker either.
- A checkpoint that asserts against live state cannot be re-run green on a stopped host: S18 fails on its own
  precondition until `make demo-up` has run.
