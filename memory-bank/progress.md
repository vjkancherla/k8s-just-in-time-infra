Updated: 2026-09-15

## Working
S19 is closed - checkpoint PASS, review CLEAR, both boxes ticked. S20 is next and its gate already passes.
S21 is not implemented; its gate fails with "no make target 'timeline'", as written.

## Done (verified)
- S19 closed: review CLEAR, no blockers; the two concerns live in `docs/reviews/S19-findings.md`.
- `docs/todo.md` and `docs/build-plan.md` carry Stage G - S19, S20, S21, two boxes each - with the timeline's
  JSON shape, five lanes, thirteen kinds and the S18 amendment fixed before any implementation.
- `scripts/checks/S19.sh`, `S20.sh`, `S21.sh` written from their Goal text and run; evidence in
  `docs/evidence/s19-retro-check.log`, `s20-retro-check.log`, `s21-pre-implementation.log`.
- S20 PASS: 19 tests, 11 ALLOWED entries all allowlisted make targets, `POST /run/state` and `/run/targets`
  404, `/deploy/.env` and `/Makefile` 404, `/state` answers, no shell, lock and log-offset tests present.
- The retrospective timeline is proven feasible on live data, by a read-only probe rather than by argument:
  four lanes, sub-second controller events, and `docker inspect` showing postgres Created 18:50:46 →
  Started 18:52:27, which is R9's `docker restart` showing up on the same axis as the app.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` restored (it was in neither the tree nor history).
- S19's fix: the snapshot mode and its three `make console` references are gone, the page always polls
  `/state`; 7 assertions pass (`205aedc..7210a8d`).

## Broken (confirmed by execution)
- Nothing reproducible. S19's finding is fixed and its gate passes; S21's missing target is the gate working.

## Suspected (read, not reproduced)
- Nothing new. The three carried from 2026-09-13 stand: postgres's password can disagree across its data
  directory, container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks fail; `ipam.py`
  has no lock of its own.

## In progress
S21: not started. Its gate fails until `scripts/timeline.sh` and `make timeline` exist.

## Blocked
- S19's review and the S18 amendment both wait on the human. Nothing else blocks.

## Learnings
- Write the gate first and it tells the truth: S21's FAIL named the missing target, and S19's retro-checkpoint
  found a target the page had been promising for a week - one reference out of three files' worth of additions.
- A `/tmp` copy of a checkpoint cannot run as-is: it does `cd "$(dirname "$0")/../.."`, so point the copy's
  `cd` at the repo. With that one change the S19 probe runs and proves the rest of the file passes.
