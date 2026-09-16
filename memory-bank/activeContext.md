Updated: 2026-09-16

## Current focus
Stage G is closed, its gate re-run green on a live cluster, and the docs deliverables Stage G owed are written:
the Review section now runs to S21 and docs/lessons.md carries a Stage G section.

## Blocked
- Nothing blocks work. Stage G and the plan's Done list are closed; the nine unticked boxes are explained in
  docs/todo.md rather than ticked.

## Done (verified)
- d7f2e41 ticks docs/todo.md only, so S20's range 6d8a835..05ba84d and S21's 05ba84d..ae5e544 are unchanged.
- bfd996b's findings read CLEAR for both steps, with "(none)" under Blockers and Concerns.
- `make targets` prints 14 names, `timeline` among them.
- Gate on a live cluster: `make demo-up` -> "17 PASS, 0 FAIL" / "PASS: demo up - voting-a", then
  `make check STEP=18` -> 12 ok lines, PASS, exit 0, recorded in docs/evidence/s18-stage-g-gate.log.
- Written this session: Stage G's Review entries (3a22fc6), the Stage G lessons section, and .gitignore rules
  for console/test_serve.py's two fixture logs. The production note already exists as README's Limits table.
- Build-plan's Done list is closed, and docs/todo.md has a "The boxes" section stating that S-1's and S0-S7's
  reviews were never run - so nine boxes stay unticked rather than implying an audit trail.
- docs/timeline.html draws a real run on five lanes (run picker, ?win=1 zoom, ?filter=); verified in headless
  Chrome. Deliberately no make target and no console route, so S18's 14 names and S19's four calls stand.

## Checkpoints
- S18 PASS (amended) at eecb02e. S19, S20, S21 each ticked + CLEAR. S17 untouched.

## Next step
Nothing is in flight: the plan is closed and the human chose to stop here. If work resumes, S22 (live lanes -
kopf.info() in the controller plus a console step) is the only unwritten item; write its checkpoint first.

## Watch out
- S19's frozen checkpoint permits the page to call only /state, /claim, /log and /run, so a /timeline route
  fails it. Drawing the lanes is a later step; live lanes (S22) also need kopf.info() in the controller.
- `make timeline` stays on demand: S21's checkpoint asserts it is not a key in the 2s /state poll.
- Ignored: the two fixture logs and graphify-out/; state.log re-dirties on every poll while a page is open.
- The host is clean after `make destroy`: no k3d cluster, no jit-* containers, console/serve.py stopped (8090
  free). A live-cluster checkpoint needs `make demo-up` (~3 min) first - S18's own guard says so.
- Events sort by `t` as text, the frozen checkpoint's own order: a fractional stamp precedes a whole one.
- `app/opencode.jsonc` is ignored but on disk with a live-looking DeepSeek key; rotate it if it moves.
- `refs/cline/checkpoints/*` snapshot `.env` and `terraform.tfstate`; never `git push --all`/`--mirror`.
