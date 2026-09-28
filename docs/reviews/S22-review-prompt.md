# S22 Review - review prompt (generated, do not abbreviate)

Copy the text between the markers **verbatim** from `docs/reviews/REVIEW-PROMPT-TEMPLATE.md`
and substitute exactly six slots. Deviations, each marked inline: the S22 note in "What to
read" and after questions 6 and 7 (S22 has no checkpoint script by design - its evidence
is the captured all-fail run), and the ADR 0005 citation in "What the step was allowed to
touch" (the re-review's contract fixes are approved decision, not scope creep).

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step S22 of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

**Goal:** all child checkpoints (`scripts/checks/S23.sh`-`S29.sh`, plus the runner
`scripts/checkpoint.sh` and the guard `scripts/review-guard.sh`) exist and all of them
fail for a readable reason — because nothing is implemented, not because the harness is
broken.

**Read:** [designs/declarers-and-consumers.md](designs/declarers-and-consumers.md)
(§Verification), this document.

**Do:**
- Copy the skill's runner into `scripts/checkpoint.sh` and the guard into
  `scripts/review-guard.sh`, with the evidence path at `docs/evidence/`. Both are
  frozen from this commit.
- Turn each child step's assertions below into `scripts/checks/S23.sh` … `S29.sh`
  in one pass. `set -euo pipefail`, `fail()`, exit non-zero. They all fail now —
  that is the point, and it proves each asserts something real.
- Add `make gate STEP=NN` to the Makefile, matching the existing idiom.

**Gate (this step's evidence, captured to
`docs/evidence/s22-all-fail.log`):** running each child checkpoint reports its
failure with a readable message and zero syntax errors.

**Gate:** the child checkpoints are frozen. `scripts/checks/S22.sh` itself does not
exist — S22's record IS the captured all-fail run.

## What the step was allowed to touch

`scripts/checkpoint.sh`
`scripts/review-guard.sh`
`scripts/s22-all-fail.sh` (ADR 0005 - derives the all-fail summary by re-running the seven)
`scripts/checks/lint-helpers.sh` (ADR 0005 - the runaway-execution guard the summarizer runs first)
`scripts/checks/S23.sh`
`scripts/checks/S24.sh`
`scripts/checks/S25.sh`
`scripts/checks/S26.sh`
`scripts/checks/S27.sh`
`scripts/checks/S28.sh`
`scripts/checks/S29.sh`
`Makefile` (the `gate` target)
`docs/build-plan.md` (Stage H)
`docs/todo.md` (Stage H rows)
`.opencode/rules/s22-declarers.md`, `opencode.json`, `RUNBOOK.md`
`docs/evidence/s22-all-fail.log`, `docs/evidence/S23.log`-`S29.log`
`docs/decisions/0005-stage-h-checkpoint-contract-fixes.md` (ADR: the approved contract
fixes applied after the first re-review - S23 verdict, S24 destroy pairs, S26
conflict/apply/cleanup, S29 precondition/U12, the `-g`/`-gt` typo, the S26 `kill 0`
trap, and the two round-3 record-builder/precondition fixes)

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this must conform to
- `docs/build-plan.md` - step S22, its checkpoint, its gate
- `git diff f0cdde0..da265a3` - what was actually done (S22 and its ADR-post-review contract fixes; the design-round artifacts sit below in f0cdde0, committed at the human's direction)
- `scripts/checks/S22.sh` - the assertion that passed
  *(S22 note: there is no `S22.sh` by design; the evidence record is
  `docs/evidence/s22-all-fail.log` and the per-checkpoint logs `docs/evidence/S23.log`
  to `S29.log`, produced by the same runner.)*

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. Checkpoints are frozen; a newly
   created one is still a finding worth raising.
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
5. Did it tick a box in `docs/todo.md`? The review box is not the implementer's to tick.
   Blocker.

## Then, run it

6. **Run `scripts/checks/S22.sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
   - *S22 note:* the equivalent of the checkpoint is the all-fail capture - run
     `./scripts/checkpoint.sh NN` for each NN in 23..29; every one is designed to FAIL at
     this point, and the gate is that each failure is a readable `FAIL:` line naming its
     precondition, and none is a syntax error.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.
   - *S22 note:* inverted for this pre-flight step - the checkpoints must still FAIL with
     nothing implemented (they do), and each must have an assertion an immutable
     implementation could eventually satisfy once S23-S29 build it.

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

Write `docs/reviews/S22-findings.md`:

    # S22 Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did the all-fail pre-flight actually assert the step's goal? one paragraph.>

Verdict rules:
- Any mechanical finding (1-5) → BLOCKED - with the deliberate exception that S22's
  purpose was to create the checkpoints under `scripts/checks/`; the rule's intent
  (none may be edited after S22) is what to verify
- A checkpoint failing for a reason other than its stated precondition → BLOCKED
- A checkpoint that cannot bite once S23-S29 are implemented → BLOCKED
- Design disagreement that changes behaviour → BLOCKED
- Everything else → CONCERNS or CLEAR

If you find nothing, say CLEAR and say what you checked. "Looks good" is not a review.

Do not start the next step. Do not offer to.
=== END REVIEW PROMPT ===
