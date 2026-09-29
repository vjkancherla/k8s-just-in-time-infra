# S24 Review - review prompt (generated, do not abbreviate)

Copy the text between the markers **verbatim** from `docs/reviews/REVIEW-PROMPT-TEMPLATE.md`
and substitute exactly six slots: the step (S24), the step number (24), the topic
(`designs/declarers-and-consumers.md`), the goal (word for word from `docs/build-plan.md`
S24), the commit range (`f39fb33..614bd46`), and the files the step named as its scope (one
path per line), plus the ADR-0008 note sanctioned by the human directive of 2026-09-29.
Deviations, marked inline: the ADR-0008 note on Q1/Q4 (the checkpoint amendment, with a
pointer to the ADR in "What to read"), and the rule-4 exemption for the review-machinery
files in the range. Add nothing else.

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step S24 of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

**Goal:** two runner changes the design calls load-bearing: the success cache keyed
on module + workspace + params hash (without it, every update POST is a cached
no-op recorded as applied), and `tofu state rm` of `postgresql_*` before destroy so
the destroy path survives the module's new logical resources.

## What the step was allowed to touch

docs/designs/runner-api.md
jit-runner/
docs/designs/declarers-and-consumers.md
docs/lessons.md
docs/evidence/S24.log
docs/decisions/0008-s24-checkpoint-setup-fixes.md
scripts/checks/S24.sh
docs/build-plan.md

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this must conform to
- `docs/build-plan.md` - step S24, its checkpoint, its gate
- `git diff f39fb33..614bd46` - what was actually done
- `scripts/checks/S24.sh` - the assertion that passed
- `docs/decisions/0008-s24-checkpoint-setup-fixes.md` - the checkpoint amendment this
  review must assess

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. Checkpoints are frozen; a newly
   created one is still a finding worth raising.
   - *S24 note:* the range touches `scripts/checks/S24.sh`, sanctioned by ADR 0008 and
     committed with it. The amendment fixes setup defects only (host-reachable runner URL,
     the redis create's required `ip`, JSON `Content-Type`, the destroy status string, and
     a positive `state rm` test that actually exercises the conditional); no assertion is
     softened. Judge ADR 0008 as a decision, not the edit as a violation.
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
   - *S24 note:* the range contains review-machinery files, not implementation:
     `docs/reviews/S24-findings.md` (the reviewer's findings) and
     `docs/reviews/S24-review-prompt.md` (the prompt re-emitted during the review cycle -
     acts of review, not of implementation). Every implementation file in the range is on
     the list above; treat the review files as exempt from rule 4.
5. Did it tick a box in `docs/todo.md`? The review box is not the implementer's to tick.
   Blocker.

## Then, run it

6. **Run `scripts/checks/S24.sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
   - *S24 note:* the checkpoint's stated precondition is the runner container up
     (`make jit-up`) and docker reachable; it may run without tenants. It drives the
     runner at `127.0.0.1:8100` (the published host port) and creates its own
     `s24-check`/`s24-pg` workspaces, so a clean run needs no leftover state.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.
   - *S24 note (ADR 0008):* the positive `state rm` test injects a `postgresql_database`
     state entry before pre-removing the container, because the postgres module creates no
     `postgresql_*` resources until S27. Without the injection the refresh succeeds whether
     or not the runner runs `state rm`, and the positive side asserts nothing. Judge
     whether the injection makes the conditional real, and whether the negative side (a
     redis-only destroy runs no `state rm`) is genuinely asserted.

## Then, on substance

8. **Where does the implementation disagree with the design?** Quote both.
9. **What does the design require that the diff does not do?**
10. **What does the diff do that the design does not mention?** Scope creep is a finding
    even when the code is good.
11. **What are the failure modes of this code that neither the design nor the checkpoint
    covers?** And what would you attack first, if you wanted this to misbehave?
12. **Would you be able to maintain this?** One line. Not style preferences - whether the
    intent is recoverable by someone who did not write it.

## Output

Write `docs/reviews/S24-findings.md`:

    # S24 Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S24.sh pass on a clean run? does it actually assert the step's goal?
    one paragraph.>

Verdict rules:
- Any mechanical finding (1-5) → BLOCKED
- Checkpoint fails when you run it → BLOCKED
- Checkpoint would pass with the logic removed → BLOCKED
- Design disagreement that changes behaviour → BLOCKED
- Everything else → CONCERNS or CLEAR

If you find nothing, say CLEAR and say what you checked. "Looks good" is not a review.

Do not start the next step. Do not offer to.
=== END REVIEW PROMPT ===
