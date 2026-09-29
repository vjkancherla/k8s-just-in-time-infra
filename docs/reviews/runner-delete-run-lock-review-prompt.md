# Review prompt — lock `delete_run` (ADR 0023 debt 1, unlocked-`delete_run` item)

You are reviewing work you did not do and have no stake in.

A different model fixed one item of accepted debt: `jit-runner`'s `delete_run` took no
`_run_lock(key)`, so a destroy could interleave with an apply on the same
`(workspace, module)`. Your job is to find what is wrong with the fix. Do not be agreeable.
Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no "while I
was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If it
has fewer, or reads like a summary, stop and write a findings file with verdict BLOCKED and
the single blocker "review prompt was abbreviated".

## What the step was supposed to do

Take `_run_lock(key)` for the **whole** of `delete_run`, matching the lock `create_run`
already holds across `_apply_run`. Two races this closes (ADR 0024, Consequences; ADR 0023
debt 1, "`delete_run` is unlocked"; `docs/reviews/runner-workdir-leak-findings.md`, concern
2):

1. **New failure mode from the work-dir fix:** destroy resolves cached work dir D1 → a
   changed-params apply completes in D2, swaps the entry and `rmtree`s D1 → the destroy's
   remaining `tofu` calls run in a deleted directory and fail. Bounded and retriable, but new.
2. **Pre-existing mirror leak:** a destroy finishing first pops the entry an apply just
   replaced, leaking D2.

Then run `scripts/checkpoint.sh 24` (runner gate) and `scripts/checkpoint.sh 27` (live
modules) and commit the code with both captured evidence logs.

## What the step was allowed to touch

```
jit-runner/main.py
docs/evidence/S24.log
docs/evidence/S27.log
```

(`docs/reviews/runner-delete-run-lock-review-prompt.md` and
`docs/reviews/runner-delete-run-lock-findings.md` are this review's own artefacts.)

## What to read

- `docs/HANDOFF.md` P0 item 1 - the task, in full
- `docs/decisions/0024-s24-workdir-leak-assertion.md` - why this is its own step
- `docs/decisions/0023-stage-h-concerns-accepted.md` - the debt bullet, and the review's
  concern 7
- `docs/reviews/runner-workdir-leak-findings.md` - concern 2 names this exact race
- `jit-runner/main.py` - `delete_run` (the change) and `create_run`/`_apply_run` (the lock
  it must match)
- `git diff a374e21..f8bf679` - what was actually done
- `scripts/checks/S24.sh`, `scripts/checks/S27.sh` - the assertions that passed

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. (`S24.sh`/`S27.sh` must be unchanged;
   the evidence logs are regenerated, not the checks.)
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
5. Did it tick a box in `docs/todo.md`? Blocker.

## Then, run it

6. **Run `scripts/checkpoint.sh 24 /tmp/S24-review.log` yourself, on the current tree.** Does
   it pass *now*? A pass for the implementer that fails for you usually means leftover state.
7. **Read the checkpoint.** Would S24 (and S27) still pass if the locking were deleted? These
   checkpoints do not assert a race directly - say plainly what they do and do not prove about
   this step, and whether that is acceptable for a debt fix whose step description named no
   checkpoint amendment.

## Then, on substance

8. **Does the locking actually serialise the two paths?** The resolve-and-destroy must be
   inside `async with _run_lock(key)` and the entry must be re-read under that lock. Quote the
   code. Does the key used for the lock match the key `create_run` uses?
9. **Is anything held across the lock that should not be** (a `threading.Lock` held across an
   `await`, a lock ordering that can deadlock against `_apply_run`), and is the lock released
   on every return path, including exceptions?
10. **What does the change do that the task did not mention?** The old code resolved the entry
    before the try; the new code re-resolves inside the lock. Enumerate every behavioural
    change (including the no-module fallback and the empty-module `""` case) and say whether
    each is intended.
11. **What are the failure modes of the new code that neither the task nor the checkpoints
    cover?** What would you attack first? Consider: a destroy that arrives while an apply is
    in flight (does it destroy the *new* run?), runner restart while a request holds the lock,
    and lock-map growth.
12. **Would you be able to maintain this?** One line. Whether the intent is recoverable by
    someone who did not write it.

## Output

Write `docs/reviews/runner-delete-run-lock-findings.md`:

    # delete_run lock review (a374e21..f8bf679)

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S24 and S27 pass on your clean runs? do they assert this step's goal? one paragraph.>

Verdict rules:
- Any mechanical finding (1-5) → BLOCKED
- A checkpoint fails when you run it → BLOCKED
- A checkpoint would pass with the logic removed **and the step claimed it asserted the
  fix** → BLOCKED; if the step made no such claim, say so as a Concern instead
- A design disagreement that changes behaviour → BLOCKED
- Everything else → CONCERNS or CLEAR

If you find nothing, say CLEAR and say what you checked. "Looks good" is not a review.

Do not start the next step. Do not offer to.
