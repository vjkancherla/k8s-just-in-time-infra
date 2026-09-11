Updated: 2026-09-11

## Current focus
S17 is reviewed (CONCERNS, no blockers — `docs/reviews/S17-findings.md`) and its concerns are disposed
of: three fixed and run-verified, two flagged. Running them found two further defects, both fixed and
verified. What remains is the human's: tick the review box, and decide the cold-path run.

## Blocked
- The review box in `docs/todo.md` — the human ticks it, not the agent.
- The cold path `make destroy` → `make all` → `make jit-up` → `make jit-verify` waits on the human (it
  deletes the k3d cluster), and reading it, `jit-up` does not import the controller image it takes with it.

## Done (verified)
- `bash scripts/checks/S17.sh` exit 0 at c95c051: J1-J11 **11 PASS**, then R1-R17 **17 PASS**
  (`docs/evidence/s17-run-postfix.log`). `make verify` was re-run green after each later change, most
  recently `17 PASS, 0 FAIL` with the `verify.sh` guard in place.
- The retry-path release: `docs/evidence/leak-probe3*` (the fix) against `leak-probe2*` (the leak).
- The stack bounce end to end: `docs/evidence/s17-jitdown-bounce.log` — ledger absent after `jit-down`,
  nothing left over after `jit-up`, claims and ledger rebuilt by a Deployment touch, `17 PASS`.
  The run that failed first and why: `docs/evidence/s17-jitdown-bounce-race.log`.
- The R-checks' unguarded `OPTS`: `docs/evidence/s17-rchecks-negative-options.log` (10 PASS, 7 FAIL, no
  shell noise, R5 fails honestly instead of passing vacuously on a dead app).

## Checkpoints (final code)
- PASS: S17, `scripts/checks/S17.sh` (exit 0) — true of c95c051. `jit-down.sh` and `app/scripts/verify.sh`
  changed after it; the gate runs neither, and the half it does run (`make verify`) is green on the new file.

## Commits
36a86b2..e00a179 the step's code; c95c051 teardown fix; 8e7bae5 review; c811966 ledger/bounce; then HEAD.

## Next step
The human ticks the S17 review box, or names the cold-path run as the next task
(`cd app && make destroy && make all`, then `make jit-up` and `make jit-verify`).

## Watch out
- Unverified, read-level: the cold path and its missing image import; `var.share_dir`'s `/tmp` default;
  `ipam.py` has no lock of its own; `_allocated_ip` cannot tell a failed read from "no address".
- Referenced by README/todo/systemPatterns but **untracked**: `docs/jit-infra-poc.md`,
  `docs/jit-infra-flows.md`, `docs/01-jit-poc.md`, `docs/decisions/`.
