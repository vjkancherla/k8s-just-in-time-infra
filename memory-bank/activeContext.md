Updated: 2026-09-15

## Current focus
Stage G's gates were written before the code: S19 (the page), S20 (the proxy), S21 (`make timeline`, build A).
**S19 is closed** - checkpoint PASS, review CLEAR (Opus 4.6, no blockers, two concerns in
`docs/reviews/S19-findings.md`), both boxes ticked. S20 is next and its gate already passes.

## Blocked
- Nothing blocks work.
- `scripts/checks/S18.sh` awaits an amendment: `claim` and now `timeline`, 12 → 14 names, unexecuted until
  approved - then `make targets` and the frozen array agree again.

## Done (verified)
- Retrospective timeline proven on live data by a 65-line read-only probe, not asserted: Deployment
  18:50:32Z → claims 18:50:33Z → postgres container 18:50:46 → runner 200 at 18:50:47.131 → Secret
  18:50:47 → all three modules up 18:51:05 → worker pod 18:52:13. Gaps real, every source named.
- Three gates written from their Goal text and run: `scripts/checks/S19.sh` (7 assertions), `S20.sh` (6),
  `S21.sh` (7, three of which re-derive events from `kubectl`, `docker inspect` and the runner's log).
- `docs/todo.md` + `docs/build-plan.md` carry Stage G: two boxes per step, the timeline's JSON shape, its
  five lanes, its thirteen kinds, and the S18 amendment - all fixed before implementation.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` restored from `S17-review-prompt.md`, six slots and all twelve
  questions.

## Checkpoints
- S18: red by design until amended (12 vs 14 names). S19: PASS + CLEAR, both boxes ticked. S20: PASS.
  S21: FAIL first, as written. S17 untouched: `make verify` = 17 PASS.

## Next step
Run S20's step: re-run `scripts/checks/S20.sh` (it passes), tick its check box, commit, emit
`docs/reviews/S20-review-prompt.md` from the template, stop. S21 needs the S18 amendment first.

## Watch out
- No phase transition is timestamped and the claims carry no conditions, so `claim.ready` lives only in the
  controller's `--timestamps` log. A live view (S22) needs `kopf.info()` in the controller - kopf 1.44
  posts events only from explicit calls (`loggers=False`) and they expire in about an hour.
- `app/opencode.jsonc` is ignored but on disk, holding a live-looking DeepSeek key. Rotate it if it moves.
- `refs/cline/checkpoints/*` snapshot `.env` and `terraform.tfstate`; never `git push --all`/`--mirror`.
- `/tmp` probes are throwaway; the durable record is `docs/evidence/s19-retro-check.log`, `s20-retro-check.log`,
  `s21-pre-implementation.log`. HEAD is 4 commits ahead of `origin/main` (unpushed) and `state.log` stays dirty.
