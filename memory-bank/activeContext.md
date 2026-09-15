Updated: 2026-09-15

## Current focus
Stage G is implemented end to end and waits only on review. S20 is ticked, S21 is built and ticked, S18's
frozen array is amended and green, and both review prompts are emitted for one combined review.

## Blocked
- Nothing blocks work. Two reviews are outstanding, and the Stage G gate needs both to say CLEAR.

## Done (verified)
- S20: `scripts/checks/S20.sh` PASS on a clean run - 19 tests, 11 ALLOWED entries all allowlisted make
  targets, POST refused for reads and unknown names, the repo not served, run lock and log offset covered.
  docs/evidence/s20-retro-check.log holds both runs.
- S21: `scripts/timeline.sh` + `make timeline` read five sources into one JSON object - 36 events, five
  lanes, all thirteen kinds for the live voting-a run. Gate PASS three times, including after S18's run
  bounced the demo. Teeth shown: a copy reporting one timestamp a second early FAILs assertion 6.
- S18 amendment: the frozen array went 12 -> 14 (`claim`, `timeline`) on the instruction to proceed with
  S21. docs/evidence/s18-amendment-timeline.log holds the 12-name FAIL and the 14-name PASS.
- `make targets` prints fourteen names; `make check STEP=18` = 12 ok lines and PASS.
- docs/reviews/S20-review-prompt.md and S21-review-prompt.md emitted, both verified verbatim against the
  template with all twelve questions.

## Checkpoints
- S18 PASS (amended). S20 PASS + ticked. S21 PASS + ticked. S19 unchanged: PASS + CLEAR, both boxes.
  S17 untouched.

## Next step
Hand both prompts to a different model together, as the human asked, and read only the findings files.

## Watch out
- The S18 amendment's header records it as approved by "proceed with s20 and s21" - the one interpretive
  call this session made. Correct that header if it was not the intended approval.
- No page or proxy change for the timeline: S19's frozen checkpoint permits the page to call only /state,
  /claim, /log and /run, so a /timeline endpoint would fail it. Drawing it is a later step.
- Events sort by `t` as text, which is the frozen checkpoint's own order: within one second a fractional
  stamp precedes a whole one.
- `console/test_serve.py` leaves untracked `docs/evidence/console-<fake>.log` litter when it runs.
- `app/opencode.jsonc` is ignored but on disk with a live-looking DeepSeek key; rotate it if it moves.
- `refs/cline/checkpoints/*` snapshot `.env` and `terraform.tfstate`; never `git push --all`/`--mirror`.
