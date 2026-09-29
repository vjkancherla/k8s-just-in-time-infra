# S25 Review - review prompt (generated, do not abbreviate)

Copy the text between the markers **verbatim** from `docs/reviews/REVIEW-PROMPT-TEMPLATE.md`
and substitute exactly six slots: the step (S25), the step number (25), the topic
(`designs/declarers-and-consumers.md`), the goal (word for word from `docs/build-plan.md`
S25), the commit range (`5ae9ba7..8910113`), and the files the step named as its scope (one
path per line), plus the ADR-sanctioned files below. Deviations, marked inline: the
ADR-0011 note on Q1/Q4/Q7 (the checkpoint amendment, with a pointer in "What to read").
Add nothing else.

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step S25 of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

**Goal:** `appliedParams`, `attemptedParamsHash`, `declaredBy` survive the API
server's pruning, plus `ParamsConflict/AwaitingDeclarer/NoDeclarer/UpdateRefused/
Updating/UpdateFailed/OutputsChanged` as conditions. `spec.params` already exists.

## What the step was allowed to touch

docs/designs/declarers-and-consumers.md
deploy/crd/infraclaim.yaml
docs/lessons.md
docs/evidence/S25.log
docs/decisions/0011-s25-checkpoint-roundtrip-namespace.md
scripts/checks/S25.sh

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this must conform to
- `docs/build-plan.md` - step S25, its checkpoint, its gate
- `git diff 5ae9ba7..8910113` - what was actually done
- `scripts/checks/S25.sh` - the assertion that passed
- `docs/decisions/0011-s25-checkpoint-roundtrip-namespace.md` - the checkpoint amendment
  (claim-locator fix) this review must assess

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. Checkpoints are frozen; a newly
   created one is still a finding worth raising.
   - *S25 note:* the range touches `scripts/checks/S25.sh`, sanctioned by ADR 0011
     (the round-trip patched the claim without a namespace). The ADR is committed with
     its edit. No assertion is deleted or weakened; the three field names, the `probe`
     values, the three read-backs and every failure message are unchanged. Judge the ADR
     as a decision, not the edit as a violation.
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
   - *S25 note:* `docs/decisions/0011-...md` and `scripts/checks/S25.sh` are on the list
     because ADR 0011 puts them in S25's scope. No other file is touched.
5. Did it tick a box in `docs/todo.md`? The review box is not the implementer's to tick.
   Blocker.

## Then, run it

6. **Run `scripts/checks/S25.sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
   - *S25 note:* the stated precondition is the cluster and CRD up (`make jit-up`) with
     at least one live InfraClaim. The checkpoint patches an existing claim's status and
     leaves the probe values there; it does not clean up.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.
   - *S25 note (ADR 0011):* the amendment only resolves the claim's namespace; the
     assertion is byte-identical. Judge whether the round-trip still catches a field that
     is missing from the schema (the API server would prune it and the read-back would
     fail).

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

Write `docs/reviews/S25-findings.md`:

    # S25 Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S25.sh pass on a clean run? does it actually assert the step's goal?
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
