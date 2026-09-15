Updated: 2026-09-15

## Current focus
Stage G exists and its gates were written before the code: S19 (the page), S20 (the proxy), S21
(`make timeline`, build A). **S19 is done and check-ticked** (`205aedc..7210a8d`) - the page named
`make console`, a target that never existed, so the snapshot mode and its three references are gone
and the gate prints PASS. Its review is the next gate, not mine to pass.

## Blocked
- Nothing blocks work. S19's review box is open until `docs/reviews/S19-findings.md` says CLEAR.
- `scripts/checks/S18.sh` awaits an amendment: `claim` and now `timeline`, 12 → 14 names, unexecuted until
  approved - then `make targets` and the frozen array agree again.

## Done (verified)
- Retrospective timeline proven on live data by a 65-line read-only probe, not asserted: Deployment
  18:50:32Z → claims 18:50:33Z → postgres container 18:50:46 → runner 200 at 18:50:47.131 → Secret
  18:50:47 → all three modules up 18:51:05 → worker pod 18:52:13. Gaps real, every source named.
- Three gates written from their Goal text and run: `scripts/checks/S19.sh` (6 assertions), `S20.sh` (6),
  `S21.sh` (7, three of which re-derive events from `kubectl`, `docker inspect` and the runner's log).
- `docs/todo.md` + `docs/build-plan.md` carry Stage G: two boxes per step, the timeline's JSON shape, its
  five lanes, its thirteen kinds, and the S18 amendment - all fixed before implementation.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` restored from `S17-review-prompt.md`, six slots and all twelve
  questions.

## Checkpoints
- S18: red by design until amended (12 vs 13 names today, 14 after). S19: FAIL (one finding). S20: PASS.
  S21: FAIL first, as written. S17 untouched: `make verify` = 17 PASS.

## Next step
Switch model, fresh task, paste `docs/reviews/S19-review-prompt.md`. Do not start S20 until
`S19-findings.md` says CLEAR. Then S20 (its gate already passes), then S21 behind its gate.

## Watch out
- No phase transition is timestamped and the claims carry no conditions, so `claim.ready` lives only in the
  controller's `--timestamps` log. A live view (S22) needs `kopf.info()` in the controller - kopf 1.44
  posts events only from explicit calls (`loggers=False`) and they expire in about an hour.
- `app/opencode.jsonc` is ignored but on disk, holding a live-looking DeepSeek key. Rotate it if it moves.
- `refs/cline/checkpoints/*` snapshot `.env` and `terraform.tfstate`; never `git push --all`/`--mirror`.
- `/tmp/timeline_probe.py` and `/tmp/S19-probe.sh` are throwaway; the durable record is the three
  `docs/evidence/*-retro-check.log` and `*-pre-implementation.log` runs.
