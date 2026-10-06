# JIT Infra PoC - working rules

These apply to every session in this workspace.

## Scope

- **All work happens inside `jit-infra-poc/`.** Never create, edit or delete a file
  outside it.
- **`local-ai-dev-workflow-voting-app/` is read-only reference.** Never modify it. The
  app is *copied* into `jit-infra-poc/app/` in step S0 and only the copy is edited.
- If a task seems to require touching either rule, stop and say so instead.

## Method

- **One step at a time.** Steps are defined in `docs/build-plan.md`. Do the current
  step only. Do not start the next one, do not "also fix" something you noticed.
- **Read only the files the step lists.** Do not scan the whole tree.
- **Every step ends at a checkpoint.** Run it. Paste the real output. Do not describe
  what the output would be.
- **A failed checkpoint stops the step.** Fix and re-run. If it fails twice, stop and
  report what you saw - do not try a third approach.
- **Do not skip ahead when blocked.** A blocked step is a result, not a detour.
- Mark the `check` box in `docs/todo.md` only after the checkpoint printed PASS.
- **A step is not finished at its checkpoint.** After it passes: commit, emit
  `docs/reviews/SNN-review-prompt.md` from the template, then STOP and tell me to switch
  models. Do not start the next step until `SNN-findings.md` says CLEAR.
- Fill only the three mechanical slots in the review prompt. Never add your own summary
  of what you did - the reviewer reads the design, not your account of it.
- A `BLOCKED` finding reopens the step. Do not argue with the reviewer; if you think a
  blocker is wrong, raise it with me.

## Code

- Simplest thing that passes the checkpoint. This is a PoC.
- No new dependencies unless the step names them.
- No refactoring outside the step's listed files.
- No `kubectl apply` of anything not in the step.
- Shell checkpoints print `PASS` or `FAIL` and exit non-zero on failure.
- **Never edit a file under `scripts/checks/`.** They were written in S-1 and are frozen.
  If a checkpoint looks wrong, stop and ask - do not adjust it to match the code.
- Unit tests are for pure logic only (time arithmetic, allocation, parsing, state
  transitions). They are your diagnostic tool, not proof the step passed. The checkpoint
  is the proof.

## When something is ambiguous

Ask. One question, then wait. Do not guess and proceed.
