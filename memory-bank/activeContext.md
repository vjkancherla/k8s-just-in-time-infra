Updated: 2026-09-11

## Current focus
S17's code is done: the retry-path IP leak is fixed, the README escape hatch corrected, and
`bash scripts/checks/S17.sh` is green again on the fixed tree (c95c051). Only the independent review is
outstanding, and it needs a different model in a fresh task.

## Blocked
- The review box in `docs/todo.md`: it stays unticked until another model writes
  `docs/reviews/S17-findings.md` with CLEAR. The prompt is current (pinned to c95c051) and committed.

## Done (verified)
- `bash scripts/checks/S17.sh` exit 0 on the fixed tree: J1-J11 **11 PASS, 0 FAIL**, then R1-R17
  **17 PASS, 0 FAIL** in voting-a (`docs/evidence/s17-run-postfix.log`, `verify-jit-postfix.md`).
- The fix, by execution: `docs/evidence/leak-probe3.sh` → `LEDGER AFTER` names voting-a only, and
  `leak-probe3-controller.log` shows the retry branch releasing after the claim is gone, then the delete
  handler skipping (twice — kopf re-delivers the deletion).
- The leak as it was: `docs/evidence/leak-probe2.sh` / `leak-probe2.log` (claim and container gone, ledger
  still counting the namespace).
- README §"If it goes wrong" step 2 now names every variable the modules require; `postgres_url` has no
  default and was missing.

## Checkpoints (final code)
- PASS: S17, `scripts/checks/S17.sh` (exit 0) at c95c051 — this is the tree the review reads.

## Commits
S17 implementation 36a86b2..e00a179; bookkeeping 4b52099..7807f38; fix c95c051 (the range end for the review).

## Next step
Run the independent review from `docs/reviews/S17-review-prompt.md` in a fresh task on a different model; the
human ticks the review box, not the agent.

## Watch out
- Latent, not reproduced: `ipam.py` has no lock of its own (now one more caller, the resync release);
  `_allocated_ip` cannot tell a failed read from "no address"; `jit-down` never reconciles the ledger; the
  gate never runs `jit-up`/`jit-down`.
- Referenced by `README.md`, `docs/todo.md` and `systemPatterns.md` but **untracked**: `docs/jit-infra-poc.md`,
  `docs/jit-infra-flows.md`, `docs/01-jit-poc.md`, `docs/decisions/`. The review can read them on disk; a
  fresh clone could not.
