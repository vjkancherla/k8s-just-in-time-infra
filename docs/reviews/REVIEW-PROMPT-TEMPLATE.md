# Review prompt template

Copy the text between the markers **verbatim** into `docs/reviews/S<NN>-review-prompt.md`
and substitute exactly six slots: `[STEP]`, `[NN]`, `[TOPIC]`, `[GOAL]`,
`[COMMIT_RANGE]`, `[FILES]`. Change nothing else, add nothing else.

- `[GOAL]` is copied **word for word** from the step in `docs/build-plan.md` - not
  paraphrased, not shortened.
- `[FILES]` is the list the step named as its scope, one path per line.
- `[TOPIC]` is the design note's filename under `docs/` (`jit-infra-poc.md` for Stages
  A-F; for Stage G the operative design is the step itself in `docs/build-plan.md`).

Never add an account of what you did: the reviewer reads the design, not your story
about it. The generated file must contain all twelve numbered questions.

After generating it, stop and print:

> S<NN> checkpoint passed, committed as `<sha>`.
> Switch to a different model, start a fresh task, paste
> `docs/reviews/S<NN>-review-prompt.md`.
> I will not start S<NN+1> until `S<NN>-findings.md` says CLEAR.

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step [STEP] of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

[GOAL]

## What the step was allowed to touch

[FILES]

## What to read

- `docs/[TOPIC]` - the design this must conform to
- `docs/build-plan.md` - step [STEP], its checkpoint, its gate
- `git diff [COMMIT_RANGE]` - what was actually done
- `scripts/checks/S[NN].sh` - the assertion that passed

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

6. **Run `scripts/checks/S[NN].sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.

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

Write `docs/reviews/S[NN]-findings.md`:

    # S[NN] Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S[NN].sh pass on a clean run? does it actually assert the step's goal?
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
