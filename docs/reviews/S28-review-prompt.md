# S28 Review - review prompt (generated, do not abbreviate)

Copied from `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` with the six slots substituted
verbatim: the step (S28), the step number (28), the topic
(`designs/declarers-and-consumers.md`), the goal (word for word from
`docs/build-plan.md` S28), the commit range (`4c97a6e..310a18a`), and the files the
step named as its scope (one path per line), plus the ADR-sanctioned files below.
Deviations, marked inline: ADR 0018 on Q1 (the one checkpoint amendment). Add nothing
else.

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step S28 of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

**Goal:** the app manifests become one declarer per module with consumers, and the
four documents drift stopped. No apply runs — before it all annotations are agreeing
declarers, after it one declarer and consumers, and both resolve to the same desired
params.

## What the step was allowed to touch

app/kustomize/base/vote-deployment.yaml
app/kustomize/base/worker-deployment.yaml
app/kustomize/base/result-deployment.yaml
docs/designs/annotation-to-state.md
docs/designs/jit-infra-flows.md
docs/designs/jit-infra-poc.md
docs/designs/README.md
docs/designs/declarers-and-consumers.md
docs/evidence/S28.log
docs/decisions/0018-s28-checkpoint-redis-declarer.md
scripts/checks/S28.sh

`docs/reviews/S28-review-prompt.md` is review machinery (it is the file you are reading);
it appears in the range because the prompt is regenerated after the code commit and does
not count against Q4.

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this must conform to
- `docs/build-plan.md` - step S28, its checkpoint, its gate
- `git diff 4c97a6e..310a18a` - what was actually done
- `scripts/checks/S28.sh` - the assertion that passed
- `docs/decisions/0018-s28-checkpoint-redis-declarer.md` - the ADR sanctioning the one
  checkpoint amendment this review must assess (Q1)

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. Checkpoints are frozen; a newly
   created one is still a finding worth raising.
   - *S28 note:* the range touches `scripts/checks/S28.sh`, sanctioned by ADR 0018 in
     commit `ce43c87`. The frozen assertion required `vote` to CONSUME redis, which
     contradicts the design's migration table (`declarers-and-consumers.md:209-213`), the
     S28 **Do** (`build-plan.md:1013`) and S29's U-table, and leaves redis with no
     declarer at all; the edit changes that one expected value from `noparams` to
     `declarer`, and the ADR is committed with the edit before `checkpoint.sh` ran. Judge
     ADR 0018 as a decision, not the edit as a violation.
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
5. Did it tick a box in `docs/todo.md`? The review box is not the implementer's to tick.
   Blocker.

## Then, run it

6. **Run `scripts/checks/S28.sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
   - *S28 note:* the checkpoint needs no cluster - `kubectl kustomize` builds the
     manifests offline and the rest are text greps and `tofu fmt -check`. Run it with a
     private log: `scripts/checkpoint.sh 28 /tmp/S28-review.log`.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.
   - *S28 note:* judge whether the `role()` parser would still pass if the `params` key
     were removed from every declarer (it should fail), and whether the `git grep` scan
     would still pass if `result-deployment.yaml` regained `params` (it should fail).
8. **Where does the implementation disagree with the design?** Quote both.
9. **What does the design require that the diff does not do?**
10. **What does the diff do that the design does not mention?** Scope creep is a finding
    even when the code is good.
11. **What are the failure modes of this code that neither the design nor the checkpoint
    covers?** And what would you attack first, if you wanted this to misbehave?
12. **Would you be able to maintain this?** One line. Not style preferences - whether the
    intent is recoverable by someone who did not write it.

## Output

Write `docs/reviews/S28-findings.md`:

    # S28 Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S28.sh pass on a clean run? does it actually assert the step's goal?
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
