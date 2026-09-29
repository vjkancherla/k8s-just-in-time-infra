# Stage H cumulative review prompt

You are reviewing an entire stage of work you did not do and have no stake in. A different
model implemented Stage H (S22-S29) of a build plan - most of S23-S29 in one autonomous
overnight run. Find what is wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no "while I
was here". Report only.

## The stage

- Design: `docs/designs/declarers-and-consumers.md`
- Plan: `docs/build-plan.md` Stage H (S22-S29)
- Tracker: `docs/todo.md` (Stage H boxes)
- **Range under review:** `b5f5cbf..HEAD` (84 commits, 99 files) - the pre-S22 design round to
  the S29 gate and the autonomous setup.

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this stage must conform to
- `docs/build-plan.md` Stage H - each step's Goal, Do, Checkpoint, Gate
- `docs/decisions/` - ADR 0007 through 0022 (0008-0022 are this stage's; 10 amend checkpoints)
- `docs/evidence/overnight-20260929T001629Z.md` - the overnight run report
- `docs/evidence/S29.log` - the committed stage-gate run
- `docs/reviews/S23-findings.md` ... `S29-findings.md` - the per-step verdicts
- `git diff b5f5cbf..HEAD -- scripts/checks/ scripts/checkpoint.sh` - every checkpoint change

## First, mechanically

1. **Was any file under `scripts/checks/` or `scripts/checkpoint.sh` changed without an ADR
   that sanctions exactly that change?** List each amended checkpoint and its sanctioning ADR.
2. **For each amended checkpoint (S24-S29), does the amendment fix a genuine harness or
   contract bug, or does it weaken the assertion to fit the code it should be gating?** This
   is the central question of the stage review. Quote the before and after of each changed
   assertion. A gate reworded after it failed is a blocker.
3. Did any step delete or weaken an existing assertion, or add a dependency the step did not
   name?
4. Did any implementation commit tick a `docs/todo.md` box (the implementer must not; only
   the orchestrator's own tick commits may)?
5. Is ADR 0007 (redis `maxmemory` mutable; an annotation-driven change is explicit approval
   for downtime) sound and correctly scoped? Judge the decision and its consequences - not
   whether the spike could measure it.

## Then, run it

6. **Run the stage gate yourself, on the cold stack:**
   `scripts/checkpoint.sh 29 /tmp/stage-h-review.log`. Does it pass now? Does it actually
   assert the design's U1-U13 and both suites (`make verify NS=voting-a` 17 PASS,
   `make jit-verify` J1-J11)? A gate that passes only because of leftover state is a blocker.
7. **Would the gate still pass if a step's core logic were stubbed or deleted?** Name any
   checkpoint that asserts nothing.

## Then, on substance

8. **Where does the cumulative diff disagree with the design?** Quote both. Focus on declarer
   vs consumer resolution, the mutability contract, the update flow, the conditions,
   backfill, and stale-`Updating` recovery.
9. What does the design require that the diff does not do?
10. What does the diff do that the design does not mention? Scope creep is a finding even
    when the code is good - this includes the 10 checkpoint amendments.
11. What are the failure modes of this stage that neither the design nor the checkpoints
    cover? What would you attack first?
12. Would you be able to maintain this? One line - whether the intent is recoverable by
    someone who did not write it.

## Output

Write `docs/reviews/STAGE-H-findings.md`:

    # Stage H Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <raised in review, would not stop a merge.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did the stage gate pass on a clean cold run? do the amended checkpoints still assert the
    steps' goals? one paragraph.>

Verdict rules:
- Any mechanical finding (1-4) → BLOCKED
- Gate fails on a cold run → BLOCKED
- An amended checkpoint no longer asserts its step's goal → BLOCKED
- Design disagreement that changes behaviour → BLOCKED
- Everything else → CONCERNS or CLEAR

This is a cumulative stage verdict. You may record per-step findings, but the verdict is for
the stage as a whole. Do not start any further work.
