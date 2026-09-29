# S29 Review - review prompt (generated, do not abbreviate)

Copied from `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` with the six slots substituted
verbatim: the step (S29), the step number (29), the topic
(`designs/declarers-and-consumers.md`), the goal (word for word from
`docs/build-plan.md` S29), the commit range (`e928480..b27f374`), and the files the
step's work touched (one path per line), plus the ADR-sanctioned files below.
Deviations, marked inline: ADR 0019 and ADR 0021 (the two checkpoint amendments), and
ADR 0020 and ADR 0022 (the controller and runner gaps the gate exposed). Add nothing
else.

=== BEGIN REVIEW PROMPT ===
You are reviewing work you did not do and have no stake in.

A different model implemented step S29 of a build plan. Your job is to find what is
wrong with it. Do not be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no
"while I was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If
it has fewer, or reads like a summary, stop and write a findings file with verdict
BLOCKED and the single blocker "review prompt was abbreviated - regenerate from template
verbatim".

## What the step was supposed to do

**Goal:** the design's verification table, once, end to end. The design named its
holder `scripts/checks/S22.sh`; in this chain the U-table lives in `S29.sh` — this
step's repo has the number, so the mapping is recorded rather than the design's
path silently renamed.

## What the step was allowed to touch

docs/designs/declarers-and-consumers.md
docs/evidence/s23-spike.log
jit-controller/main.py
jit-runner/main.py
scripts/checks/S29.sh
docs/decisions/0019-s29-checkpoint-contract-fixes.md
docs/decisions/0021-s29-gate-ordering.md
docs/decisions/0020-s29-ttl-maximum-and-create-contract-scope.md
docs/decisions/0022-runner-destroy-structured-params.md
docs/evidence/S29.log

`docs/reviews/S29-review-prompt.md` is review machinery (it is the file you are reading);
it appears in the range because the prompt is regenerated after the code commit and does
not count against Q4.

## What to read

- `docs/designs/declarers-and-consumers.md` - the design this must conform to, §Verification (U1-U13) and §Update flow
- `docs/build-plan.md` - step S29, its checkpoint, its gate
- `git diff e928480..b27f374` - what was actually done
- `scripts/checks/S29.sh` - the assertion that passed
- `docs/evidence/S29.log` - the captured run (never typed)
- `docs/evidence/s23-spike.log` - the measured tolerance U1 leans on
- `docs/decisions/0019-s29-checkpoint-contract-fixes.md` - the ADR sanctioning the
  checkpoint contract fixes (Q1)
- `docs/decisions/0021-s29-gate-ordering.md` - the ADR sanctioning the gate reorder (Q1)
- `docs/decisions/0020-s29-ttl-maximum-and-create-contract-scope.md` - the controller
  gaps the gate exposed (Q8/Q10)
- `docs/decisions/0022-runner-destroy-structured-params.md` - the runner gap the gate
  exposed (Q8/Q10)

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required. Checkpoints are frozen; a newly
   created one is still a finding worth raising.
   - *S29 note:* the range touches `scripts/checks/S29.sh`, sanctioned by ADR 0019
     (`982dc05`) and ADR 0021 (`346a9ad`), each committed with its edit before
     `scripts/checkpoint.sh 29` ran. The first run of the frozen U-table exposed four
     contract defects a correct implementation cannot satisfy (U1's IP locator compared
     a per-network address against `<ip>:<port>`; U5 deleted the declarer U9-U11 need;
     U6's "declarer" had no `params` key, which the role rule makes a consumer; the gate
     ran R3 with `demo-up`'s demo toggle on). ADR 0019 fixed those; ADR 0021 replaced the
     first cut's racy `set env` toggle with running the J-suite first. Judge the two ADRs
     as decisions, not the edits as violations.
2. Did it add a dependency the step did not name? Blocker.
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
5. Did it tick a box in `docs/todo.md`? The review box is not the implementer's to tick.
   Blocker.

## Then, run it

6. **Run `scripts/checks/S29.sh` yourself.** Does it pass *now*, on the current working
   tree?
   - If it fails: **blocker**. A checkpoint that passed for the implementer and fails for
     you usually means the step only worked because of leftover state.
   - *S29 note:* the precondition is `make demo-up` (voting-a) and the test tenant
     (voting-b). The checkpoint is long and destructive - it deletes `voting-a` at U12 -
     so run it with a private log: `scripts/checkpoint.sh 29 /tmp/S29-review.log`, and
     re-establish both tenants afterwards. It ran green in the captured log with
     `U1-U11, U13 ok`, `gate ok: make jit-verify reports J1-J11 all PASS`,
     `gate ok: make verify NS=voting-a reports 17 PASS, 0 FAIL`, `U12 ok`, and
     `PASS S29: U1-U13 asserted live`.
7. **Now read the checkpoint.** Would it still pass if the core logic of this step were
   deleted or stubbed out? If yes it is asserting nothing - **blocker**.
   - *S29 note:* the U-table leans on the controller's real update flow (U1 needs the
     container command to change; U2 needs a real `postgresql_database` resource; U9/U10
     need the failure and crash-recovery branches; U11 needs the backfill; U13 needs rule
     7). The gate then runs the frozen J-suite and R-suite in full. It fails readably on
     every U with nothing built.

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

Write `docs/reviews/S29-findings.md`:

    # S29 Review

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S29.sh pass on a clean run? does it actually assert the step's goal?
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
