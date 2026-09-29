# S23 Review - review prompt (generated, do not abbreviate)

Copy the text between the markers **verbatim** from `docs/reviews/REVIEW-PROMPT-TEMPLATE.md`
and substitute exactly six slots: the step (S23), the step number (23), the topic
(`designs/declarers-and-consumers.md`), the goal (word for word from `docs/build-plan.md`
S23), the commit range (`4fd26b9..b7c6650`), and the files the step named as its scope (one
path per line), plus the ADR-0007 note sanctioned by the human directive of 2026-09-28.
Deviations, marked inline: the ADR-0007 note on Q6/Q7 (with a pointer to the ADR in "What to
read"), the Q6 note that the committed spike log predates the probe hardening the human
directive says to keep as measured, and the rule-4 exemption for the review-machinery files
in the range. Add nothing else.

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step S23 of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

**Goal:** measure what the mutability contract may only claim after measurement —
how long a redis and a postgres container replace take, how many queued votes a
redis replace drops, whether `vote`/`worker` reconnect — and confirm whether
`call_runner` runs synchronously inside a `kopf` handler (it must move to
`asyncio.to_thread` if it does). The verdict decides whether redis `maxmemory`
stays in the mutable surface (U1).

## What the step was allowed to touch

docs/designs/declarers-and-consumers.md
jit-controller/main.py
docs/lessons.md
docs/evidence/s23-spike.sh
docs/evidence/s23-spike.log
docs/evidence/S23.log
docs/decisions/0007-maxmemory-mutable-despite-replace-cost.md

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this must conform to
- `docs/build-plan.md` - step S23, its checkpoint, its gate
- `git diff 4fd26b9..b7c6650` - what was actually done
- `scripts/checks/S23.sh` - the assertion that passed
- `docs/decisions/0007-maxmemory-mutable-despite-replace-cost.md` - the human decision
  this review must assess

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. Checkpoints are frozen; a newly
   created one is still a finding worth raising.
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
   - *S23 note:* the range contains review-machinery files, not implementation:
     `docs/reviews/S23-findings.md` (the reviewer's findings) and
     `docs/reviews/S23-review-prompt.md` (the prompt re-emitted during the review cycle -
     acts of review, not of implementation). Every implementation file in the range is on
     the list above; treat the review files as exempt from rule 4.
5. Did it tick a box in `docs/todo.md`? The review box is not the implementer's to tick.
   Blocker.

## Then, run it

6. **Run `scripts/checks/S23.sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
   - *S23 note:* the checkpoint's stated precondition (`make jit-up` and the demo stack in
     `voting-a`) was satisfied when the human ran the probe protocol; `S23.sh` itself reads
     only `docs/evidence/s23-spike.log`, so it re-runs without a live cluster. That is by
     design - see the Q7 note.
   - *S23 note:* `docs/evidence/s23-spike.log` is the measurement kept as-is under the
     human directive of 2026-09-28, so it predates the probe hardening in this range
     (rerun-overwrite guard, reconnect rc-checks). Those assertions were re-validated end
     to end on a `/tmp` copy via `S23_SPIKE_LOG` with the committed log untouched; the
     committed numbers (redis 0.81s, postgres 0.85s, 50/50 lost, both reconnects OK) were
     reproduced.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.
   - *S23 note (ADR 0007):* Do **not** turn the Q7 stub-test into a blocker here. S23's
     core logic is a live measurement a human ran, and the checkpoint is by design a
     paperwork gate over that human-run protocol: it asserts the evidence log contains
     measured replace timings for both containers, a lost-votes count, reconnect
     observations, the `call_runner` blocking verdict, and the final `VERDICT:` line. The
     probe measures the numbers; it does not decide mutability. **Judge ADR 0007 instead:**
     is its reasoning sound (a <=1s replace, with the worker's *startup* reconnect and
     `vote`'s per-request reachability, versus 50 of 50 queued votes lost, accepted as
     explicit annotation-driven downtime approval) and is its scope correct (redis
     `maxmemory` only; U7's remove-database, rename `postgres_db` and password-change
     refusals untouched)? ADR 0007 is the human approval this review must assess as a
     decision, not re-derive by measurement. The trailing `VERDICT: maxmemory mutable` line
     in `docs/evidence/s23-spike.log` is that decision, not a probe result.

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

Write `docs/reviews/S23-findings.md`:

    # S23 Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S23.sh pass on a clean run? does it actually assert the step's goal?
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
