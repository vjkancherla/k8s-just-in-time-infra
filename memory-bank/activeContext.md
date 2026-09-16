Updated: 2026-09-16

## Current focus
Stage G is closed, its gate re-run green on a live cluster, and the docs deliverables Stage G owed are written:
the Review section now runs to S21 and docs/lessons.md carries a Stage G section.

## Blocked
- Nothing blocks work, but build-plan's Done list cannot be closed by writing alone: docs/todo.md has 9 lines
  unticked - S-1's check and review boxes, and S0-S7's review boxes - and no findings file exists below S08.

## Done (verified)
- d7f2e41 ticks docs/todo.md only, so S20's range 6d8a835..05ba84d and S21's 05ba84d..ae5e544 are unchanged.
- bfd996b's findings read CLEAR for both steps, with "(none)" under Blockers and Concerns.
- `make targets` prints 14 names, `timeline` among them.
- Gate on a live cluster: `make demo-up` -> "17 PASS, 0 FAIL" / "PASS: demo up - voting-a", then
  `make check STEP=18` -> 12 ok lines, PASS, exit 0, recorded in docs/evidence/s18-stage-g-gate.log.
- Written this session: Stage G's Review entries (3a22fc6), the Stage G lessons section, and .gitignore rules
  for console/test_serve.py's two fixture logs. The production note already exists as README's Limits table.

## Checkpoints
- S18 PASS (amended) at eecb02e. S19, S20, S21 each ticked + CLEAR. S17 untouched.

## Next step
Decide the 9 unticked lines - review S-1..S07, or record that their review boxes stay unticked - then tick
build-plan's four Done items, which the repo now otherwise satisfies.

## Watch out
- S19's frozen checkpoint permits the page to call only /state, /claim, /log and /run, so a /timeline route
  fails it. Drawing the lanes is a later step; live lanes (S22) also need kopf.info() in the controller.
- `make timeline` stays on demand: S21's checkpoint asserts it is not a key in the 2s /state poll.
- Only untracked files left: docs/evidence/console-{failing,hello}.log, the fixtures console/test_serve.py
  writes on every run. Every other change is committed.
- The demo stack is up on this host after the gate run (voting-a, cluster voting-app): `make destroy` when the
  laptop is wanted back.
- Events sort by `t` as text, the frozen checkpoint's own order: a fractional stamp precedes a whole one.
- `app/opencode.jsonc` is ignored but on disk with a live-looking DeepSeek key; rotate it if it moves.
- `refs/cline/checkpoints/*` snapshot `.env` and `terraform.tfstate`; never `git push --all`/`--mirror`.
