# Review prompt — runner robustness (ADR 0023 debt 1: silent state-list, prefix-only filter, silent cleanup, cancelled handlers)

You are reviewing work you did not do and have no stake in.

A different model fixed four accepted-debt items in `jit-runner/main.py`. Your job is to
find what is wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no "while I
was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If it
has fewer, or reads like a summary, stop and write a findings file with verdict BLOCKED and
the single blocker "review prompt was abbreviated".

## What the step was supposed to do

Four items, all from ADR 0023 debt 1 (runner), named verbatim in `docs/HANDOFF.md` P0.2:

1. **Silent `state list` skip.** A `state list` failure degraded to "no `postgresql_*`" and
   proceeded into the destroy S24 exists to prevent. Make a failed read refuse, not proceed.
2. **Prefix-only filter.** `line.strip().startswith("postgresql_")` misses wrapped/qualified
   addresses.
3. **Silent cleanup.** Every removal used `ignore_errors=True` — a failed removal is silent
   and never retried.
4. **Cancelled handlers leak.** `except Exception` does not catch `asyncio.CancelledError`,
   so a cancelled handler leaks its fresh work dir.

Nothing else in the runner was in scope. The runner was rebuilt (`make jit-up`) and
`scripts/checkpoint.sh 24` and `27` pass; their logs are committed.

## What the step was allowed to touch

```
jit-runner/main.py
docs/evidence/S24.log
docs/evidence/S27.log
```

## What to read

- `docs/HANDOFF.md` P0.2 - the four items, in full
- `docs/decisions/0023-stage-h-concerns-accepted.md` - debt 1
- `docs/reviews/runner-workdir-leak-findings.md` - Notes Q5 (the leak paths this touches)
- `jit-runner/main.py` - the change
- `git diff 071dd24..6105ce2` - what was actually done
- `scripts/checks/S24.sh`, `scripts/checks/S27.sh` - the assertions that passed

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required.
2. Did it add a dependency the step did not name? Blocker. (A stdlib import is not a
   dependency; say so if that is all.)
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
5. Did it tick a box in `docs/todo.md`? Blocker.

## Then, run it

6. **Run `scripts/checkpoint.sh 24 /tmp/S24-review.log` and
   `scripts/checkpoint.sh 27 /tmp/S27-review.log` yourself.** Do they pass *now*? A pass for
   the implementer that fails for you usually means leftover state.
7. **Read the checkpoints.** Do they assert any of these four fixes? If they would pass with
   the fix removed, say which assertions are blind to it. (The implementer's own
   discriminating probe is in Notes; reproduce or attack it.)

## Then, on substance

8. **Item 1 (refuse).** The code treats `state list` rc != 0 as a real read failure to refuse
   *except* when stderr contains `"No state file was found"`, which it treats as an empty
   workspace and proceeds. Is that distinction sound? What happens to a cold destroy of a
   never-applied workspace, and to a destroy whose state is genuinely unreadable? Would you
   attack the substring match, and with what?
9. **Item 2 (filter).** Does the regex `(?:^|\.)postgresql_[A-Za-z0-9_]+\.` match every
   address the module and its `state rm` need, and nothing it must not (e.g. a data source,
   or a resource of another type whose name merely contains `postgresql_`)? Does `state rm`
   receive the exact addresses `state list` printed (trimmed)?
10. **Item 3 (cleanup).** Is `_rmtree` behaviour-preserving (never raises) while making a
    failure visible? Is any removal path now able to raise, or to remove a directory a retry
    still needs?
11. **Item 4 (cancellation).** Does the new `except asyncio.CancelledError` clean up the
    right dir and re-raise? For `delete_run`, is "remove only if not cached" correct? Is the
    claim in the comment - "there is no await between the entry swap and the return" in
    `_apply_run` - actually true? What other cancellation points remain uncovered?
12. **Would you be able to maintain this?** One line. Whether the intent is recoverable by
    someone who did not write it.

## Notes for the reviewer

- The implementer's discriminating probe, run inside the container:
  `docker exec -i jit-runner /opt/venv/bin/python - <<'PY' ... PY` monkeypatches
  `main._run_tofu_async` so `state list` fails; with stderr "connection refused" the response
  is `error` containing `refusing to destroy on an unreadable state`, and with stderr
  "No state file was found!" it is `destroyed`. Both asserted.
- The checkpoints do not cover any of these four fixes; expect that to be a Concern.

## Output

Write `docs/reviews/runner-r1-robustness-findings.md`:

    # runner robustness review (071dd24..6105ce2)

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S24 and S27 pass on your clean runs? do they assert any of these four fixes? one
    paragraph.>

Verdict rules:
- Any mechanical finding (1-5) → BLOCKED
- A checkpoint fails when you run it → BLOCKED
- A checkpoint would pass with the logic removed **and the step claimed it asserted the
  fix** → BLOCKED; the step made no such claim, so say it as a Concern instead
- A design disagreement that changes behaviour → BLOCKED
- Everything else → CONCERNS or CLEAR

If you find nothing, say CLEAR and say what you checked. "Looks good" is not a review.

Do not start the next step. Do not offer to.
