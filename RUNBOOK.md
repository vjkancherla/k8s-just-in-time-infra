# Runbook

How to run one step. Keep this open; everything else is reference.

Design: `docs/designs/declarers-and-consumers.md` · Plan: `docs/build-plan.md`
Stage H · Tracker: `docs/todo.md` Stage H.

## The loop

```
1. IMPLEMENT  implementer model, new session:  "Do S<N> from docs/build-plan.md"
              → checkpoint PASS, captured to docs/evidence/S<N>.log,
                committed with the code, review prompt emitted → STOPS
2. REVIEW     different model, NEW session:   "Read and follow
                docs/reviews/S<N>-review-prompt.md"
              → writes docs/reviews/S<N>-findings.md
3. RESOLVE    back to implementer, new session
              CLEAR → tick both boxes, next step
              BLOCKED → "Read S<N>-findings.md and fix the blockers"
```

## Step 1 — implement

New session, implementer model:

    Do S<N> from docs/build-plan.md

It runs the checkpoint only via `scripts/checkpoint.sh <NN>`, commits code **and**
`docs/evidence/<N>.log` together, emits `docs/reviews/S<NN>-review-prompt.md` from
`docs/reviews/REVIEW-PROMPT-TEMPLATE.md` (six slots filled verbatim, nothing added),
prints the stop message, and stops. `scripts/review-guard.sh <NN>` must print PASS
before the prompt goes anywhere.

`make check STEP=<N>` is the bare reader for the older steps; Stage H evidence
always comes from the runner.

## Step 2 — review

Switch the model (`/models`) — a different family, not a different quant. `/new`,
never a continuation.

    Read and follow docs/reviews/S<N>-review-prompt.md

It re-runs the checkpoint with its own log path
(`scripts/checkpoint.sh <NN> /tmp/S<N>-review.log`).

## Step 3 — resolve

**CLEAR:** tick both boxes in `docs/todo.md`. **BLOCKED:** fix blockers only,
re-run the checkpoint, never tick a box, re-review in a fresh session. A range
under review must end before the tracker tick (Stage-G lesson: ranges that contain
the tick come back BLOCKED).

## Which model reviews what (Stage H)

| Steps | Reviewer |
|---|---|
| S22, S23, S24, S25 | any model other than the implementer |
| S26 (controller core), S27 (modules), S28 (migration), S29 (the gate) | strongest available, including cloud |

## Preconditions

- Most checkpoints need the demo stack up (`make demo-up`); each says so and fails
  rather than skips. S26 runs against the stub runner and needs no cluster.
- Module changes are baked into the runner image: after S27's edits, rebuild
  before believing any live assertion.

## At the stage boundary

1. Cold teardown first: `make jit-down`, then the cold order the README's
   "From cold" section records, before re-running the gate.
2. Cumulative stage review by the strongest model.
3. Read one file yourself, chosen at random.

## Things that mean stop

- Anything under `scripts/checks/` or `scripts/checkpoint.sh` edited without an ADR
- A step called done while `docs/evidence/S<N>.log` is not in its commit
- An evidence log edited, truncated or retyped
- A review CLEAR in one line, with nothing checked
- `scripts/review-guard.sh` fails
- The same step BLOCKED three times — that's a design problem; stop

## If I only remember one thing

**New session for the review, never a continuation.** A reviewer that saw the
implementer's reasoning is not reviewing; it is agreeing.
