# S26 Review - review prompt (generated, do not abbreviate)

Copied from `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` with the six slots substituted
verbatim: the step (S26), the step number (26), the topic
(`designs/declarers-and-consumers.md`), the goal (word for word from
`docs/build-plan.md` S26), the commit range (`dd49333..03bbc96`), and the files the
step named as its scope (one path per line), plus the ADR-sanctioned files below.
Deviations, marked inline: the ADR-0012 and ADR-0013 notes on Q1/Q3/Q4/Q6/Q7 (the
two checkpoint amendments, with pointers in "What to read"), and ADR 0014, which
records ADR 0007's delegated executor-pool decision (What to read / Q9). Add
nothing else.

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step S26 of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

**Goal:** the genuinely new logic — declarer resolution, the mutability contract
and validation, the update flow, backfill, stale-`Updating` recovery — proven with
a wrong state transition costing nothing. **No real module runs here.**

## What the step was allowed to touch

jit-controller/main.py
jit-controller/stub_runner.py
jit-controller/test_declarers.py
docs/evidence/S26.log
docs/decisions/0012-s26-checkpoint-harness-fixes.md
docs/decisions/0013-s26-group8-second-namespace.md
docs/decisions/0014-s26-executor-pool-decision.md
scripts/checks/S26.sh

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this must conform to
- `docs/build-plan.md` - step S26, its checkpoint, its gate
- `git diff dd49333..03bbc96` - what was actually done
- `scripts/checks/S26.sh` - the assertion that passed
- `docs/decisions/0012-s26-checkpoint-harness-fixes.md` and
  `docs/decisions/0013-s26-group8-second-namespace.md` - the two checkpoint
  amendments this review must assess
- `docs/decisions/0007-maxmemory-mutable-despite-replace-cost.md` - the step's
  binding context: redis `maxmemory` is mutable, so an edit to it must apply
- `docs/decisions/0014-s26-executor-pool-decision.md` - ADR 0007's delegated
  executor-pool decision: the sync handlers are kept and the 6-worker bound is
  documented, not changed. Judge it as a decision (Q9).

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. Checkpoints are frozen; a newly
   created one is still a finding worth raising.
   - *S26 note:* the range touches `scripts/checks/S26.sh`, sanctioned by ADR 0012
     (six unsatisfiable harness/contract defects: the `make` helper passed its data to
     `kubectl apply`; nine reads omitted `-n "$NS"`; `stub_get` grepped the claim name
     where the runner workspace is the namespace; groups 5-6 left a disagreeing declarer
     in place; groups 8-9 waited on a claim no design-conforming controller creates; the
     stub run was not namespace-confined) and ADR 0013 (group 8 uses a second scratch
     namespace instead of recreating the first, because a namespace-scoped watch does not
     run the claim's delete handler while the namespace terminates). Both ADRs are
     committed with their edits. No assertion is deleted or weakened: every group's
     `ok:` line and failure message is unchanged, and the assertion text is identical
     apart from the namespace/workspace locators the ADRs enumerate. Judge the ADRs as
     decisions, not the edit as a violation.
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
   - *S26 note:* `jit-controller/test_declarers.py` is new. No existing test was edited
     or removed. `check_param_conflict` (first-writer-wins) was replaced by declarer
     resolution, which the design requires; it had no test of its own.
4. Did it create or edit files outside the list above? Blocker.
   - *S26 note:* `docs/decisions/0012-...md`, `docs/decisions/0013-...md`,
     `docs/decisions/0014-...md` and `scripts/checks/S26.sh` are on the list because
     the ADRs put them in S26's scope.
   - *S26 note:* `docs/reviews/S26-review-prompt.md` is review machinery, present in
     the range because the prompt was emitted before ADR 0014 was recorded and
     re-emitted after; it is exempt from rule 4's file list. Every implementation file
     is on the list.
5. Did it tick a box in `docs/todo.md`? The review box is not the implementer's to tick.
   Blocker.

## Then, run it

6. **Run `scripts/checks/S26.sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
   - *S26 note:* the stated precondition is the cluster and CRD up (`make jit-up`) only -
     no tenants and no runner. The script scales the in-cluster controller to 0, starts
     its own stub runner on port 8999 and a local controller watching only `jit-stub` and
     `jit-stub-consumer`, then restores the in-cluster controller and deletes both
     namespaces. No real container is created by the step; the in-cluster controller may
     process the scratch teardown after the script exits, through the real runner as a
     no-op.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.
   - *S26 note (ADR 0012/0013):* the amendments fix locators, setup and confinement only.
     The nine groups still assert declarer resolution (`spec.params` projected,
     `declaredBy`), `ParamsConflict` among declarers with no runner call, the refusal of
     a bad value and an unknown key with no POST, a real update reaching the stub with
     `appliedParams`/`attemptedParamsHash`/`Updating`, the failure branch keeping `Ready`
     with one attempt, `NoDeclarer`, `AwaitingDeclarer` on a consumer-only new claim, and
     stale-`Updating` recovery. Judge whether those still fail if the logic is absent.
     Note that the frozen groups never asserted backfill or the new-declarer-after-a-gap
     path; those are covered by `test_declarers.py` and, live, by S29/U11.

## Then, on substance

8. **Where does the implementation disagree with the design?** Quote both.
9. **What does the design require that the diff does not do?**
   - *S26 note:* ADR 0007 delegates the executor-pool ceiling to S26; ADR 0014
     resolves it by keeping the synchronous handlers and recording the bound
     (Q9 in this prompt is about the design, not ADR 0007's delegation, so treat
     ADR 0014 as the answer to that delegation and judge its reasoning).
10. **What does the diff do that the design does not mention?** Scope creep is a finding
    even when the code is good.
11. **What are the failure modes of this code that neither the design nor the checkpoint
    covers?** And what would you attack first, if you wanted this to misbehave?
12. **Would you be able to maintain this?** One line. Not style preferences - whether the
    intent is recoverable by someone who did not write it.

## Output

Write `docs/reviews/S26-findings.md`:

    # S26 Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S26.sh pass on a clean run? does it actually assert the step's goal?
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
