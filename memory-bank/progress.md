Updated: 2026-09-15

## Working
Stage G is complete except for review: S20 ticked and green, S21 built, ticked and green, S18's array
amended and green, both review prompts emitted and waiting on a different model.

## Done (verified)
- S20: gate PASS on a clean run - 19 tests, 11 ALLOWED entries all allowlisted make targets, POST
  /run/state and /run/targets 404, the repo not served, /state answering, run-lock and log-offset tests
  present. Two runs in docs/evidence/s20-retro-check.log.
- S21: `scripts/timeline.sh` is a read model in state.sh's idiom - five sources, one JSON object, one
  event per step per subject, first-seen wins, no computed intervals. Live run: 36 events, five lanes,
  thirteen kinds, 18:50:32 -> 18:52:27, and 4408s once S18's redeploy was on the axis. `timeline` joined
  CONSOLE_TARGETS, so `make targets` prints fourteen names.
- S21's gate PASS three times, and FAILs as it must against a copy that reports one timestamp a second
  early - docs/evidence/s21-checkpoint.log.
- S18: array amended 12 -> 14 on the instruction to proceed with S21; docs/todo.md's pending-amendment
  note is gone; 12-name FAIL then 14-name PASS in docs/evidence/s18-amendment-timeline.log.
- Both prompts verified verbatim against REVIEW-PROMPT-TEMPLATE.md, twelve numbered questions each.

## Broken (confirmed by execution)
- Nothing reproducible. Both FAILs this session were deliberate: the S21 teeth probe, and the 12-name
  S18 array before its amendment.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data directory,
  container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks fail; `ipam.py` has no
  lock of its own.

## In progress
Nothing. Both steps stopped where the protocol says to: prompts emitted, next step not started.

## Blocked
- S20's and S21's reviews wait on a different model. Nothing else blocks.

## Learnings
- A retro-checkpoint has no implementation commit to review, so the reviewed diff is the record commit; the
  prompt's file list must name what the step touched, or question 4 blocks on the tracker and evidence files.
- Write the gate first, then prove its teeth: S21's FAIL came from one timestamp moved one second.
