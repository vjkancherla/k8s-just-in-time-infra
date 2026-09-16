Updated: 2026-09-16

## Current focus
Stage G is closed on paper: S19, S20 and S21 all hold ticked check and review boxes and CLEAR findings, and
the tick commit left both reviewed ranges untouched. One gate line still needs a live cluster.

## Blocked
- Nothing blocks work. `make check STEP=18` cannot be re-run green until the stack is up: it stops on
  "FAIL: make state says up=false" because the console's own Destroy run took the cluster down.

## Done (verified)
- d7f2e41 ticks docs/todo.md only, so S20's range 6d8a835..05ba84d and S21's 05ba84d..ae5e544 are unchanged.
- bfd996b's findings read CLEAR for both steps, with "(none)" under Blockers and Concerns.
- `make targets` prints 14 names, `timeline` among them.
- `make check STEP=18` on the current tree: "ok: all 14 targets defined", "ok: make targets prints the
  allowlist and nothing else", "ok: make state emits the documented JSON", then the no-cluster FAIL.

## Checkpoints
- S18 PASS (amended) at eecb02e. S19, S20, S21 each ticked + CLEAR. S17 untouched.

## Next step
Bring the stack up and re-run the gate - `make demo-up && make check STEP=18` - then record that run in
docs/evidence/; it is the last open line of Stage G's gate.

## Watch out
- S19's frozen checkpoint permits the page to call only /state, /claim, /log and /run, so a /timeline route
  fails it. Drawing the lanes is a later step; live lanes (S22) also need kopf.info() in the controller.
- `make timeline` stays on demand: S21's checkpoint asserts it is not a key in the 2s /state poll.
- Uncommitted: .gitignore (graphify-out/), docs/evidence/{console-destroy,destroy,state,targets,timeline}.log,
  and untracked console-{failing,hello}.log litter from console/test_serve.py.
- Events sort by `t` as text, the frozen checkpoint's own order: a fractional stamp precedes a whole one.
- `app/opencode.jsonc` is ignored but on disk with a live-looking DeepSeek key; rotate it if it moves.
- `refs/cline/checkpoints/*` snapshot `.env` and `terraform.tfstate`; never `git push --all`/`--mirror`.
