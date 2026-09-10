# Runbook

How to run one step. Keep this open; everything else is reference.

## The loop

```
  ┌─────────────────────────────────────────────────┐
  │  1. IMPLEMENT   implementer model, new task     │
  │       "Do S3 from docs/build-plan.md"          │
  │                    ↓                            │
  │     checkpoint PASS → commit → emits            │
  │     docs/reviews/S03-review-prompt.md          │
  │     then STOPS                                  │
  ├─────────────────────────────────────────────────┤
  │  2. REVIEW      different model, NEW task       │
  │       "Read and follow                          │
  │        docs/reviews/S03-review-prompt.md"      │
  │                    ↓                            │
  │     writes docs/reviews/S03-findings.md        │
  ├─────────────────────────────────────────────────┤
  │  3. RESOLVE     back to implementer, new task   │
  │     CLEAR    → tick both boxes, go to S4        │
  │     BLOCKED  → "Read S03-findings.md and fix    │
  │                 the blockers"                   │
  └─────────────────────────────────────────────────┘
```

## Step 1 — implement

New Cline task. Implementer model selected.

```
Do S3 from docs/build-plan.md
```

It reads the step, does the work, runs `scripts/checks/S03.sh`, commits, writes the
review prompt, and stops. If it offers to start S4, it has broken protocol - say so.

## Step 2 — review

**Switch the model** in Cline's model selector. Different family from the implementer,
not a different quant of the same one.

**Start a new task.** The `+` button, not a continuation. Clearing context is not the
same thing - the point is that the reviewer never saw the implementer's reasoning.

```
Read and follow docs/reviews/S03-review-prompt.md
```

The reviewer will read the design note, the build plan, the diff and the checkpoint
script, run the checkpoint itself, and write `docs/reviews/S03-findings.md`.

Approve the commands it asks to run - it needs `git diff` and the checkpoint.

## Step 3 — resolve

Switch back to the implementer. New task.

**CLEAR:**
```
S03 review came back CLEAR. Tick both boxes in docs/todo.md, then stop.
```
Then start S4 in a fresh task.

**BLOCKED:**
```
Read docs/reviews/S03-findings.md. Fix the blockers only - not the concerns or
notes. Re-run scripts/checks/S03.sh. Do not tick any box.
```
Then re-review with the same reviewing model, new task again. Repeat until CLEAR.

**CONCERNS:** your call. Log the decision either way:
```
Read docs/reviews/S03-findings.md. Add each concern to docs/lessons.md with my
decision: <accept / fix / defer> and one line of reasoning.
```

## Which model reviews what

| Steps | Reviewer |
|---|---|
| Most | Any local model other than the implementer |
| **S10** state machine, **S14** integration, **S15** migration | Strongest available, including cloud |

Those three are where a missed error costs days rather than minutes.

## Things that mean stop

- The implementer starts the next step without a CLEAR
- The implementer edits anything under `scripts/checks/`
- A review comes back CLEAR in one line with nothing checked
- `scripts/review-guard.sh` fails
- The same step gets BLOCKED three times - that is a design problem, not a code problem

## If you only remember one thing

**New task for the review, not a continuation.** A reviewer that saw the implementer's
reasoning is not reviewing, it is agreeing.
