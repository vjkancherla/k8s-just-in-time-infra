Updated: 2026-09-11

## Current focus
S17 is reviewed (CONCERNS, no blockers) and its concerns are dispositioned: 1-3 fixed and run-verified, 4
narrowed to one open design question, 5 open by design. The decision **tenants never run in `default`** is
applied and committed, and the demo is healthy (three claims Ready, three pods 1/1).

## Blocked
- **The cold start, on one design question.** It now reaches provisioning and stops at
  `FATAL: password authentication failed for user "postgres"`: the postgres data volume survives the
  container sweep (`docker rm -f`, not a `tofu destroy`) while the controller writes a fresh password for
  the new stack. Decide: the volume goes with its container, or the password is persisted.
  Evidence: `docs/evidence/s17-cold-path.log`.
- The review box in `docs/todo.md` — the human ticks it.

## Done (verified)
- The concern fixes: `jit-down` clears the ledger; the escape hatch names it; `share_dir` documented.
- The bounce and the two defects it found: `s17-jitdown-bounce.log` vs `-race.log`; the `OPTS` guard
  (`s17-rchecks-negative-options.log`).
- Cold-start traps fixed: `jit-up` imports the controller image (16s, was 180s of ImagePullBackOff);
  `jit-down` survives a cluster with no CRD; a bare `make all` lands in `voting-a`.
- The retry-path release: `leak-probe3*` against `leak-probe2*`.

## Checkpoints (final code)
- PASS: S17, `scripts/checks/S17.sh` (exit 0) at c95c051. Since then `scripts/jit-*.sh`, `app/Makefile` and
  `app/scripts/{verify,deploy}.sh` changed; the gate runs none of them, and `make verify` — the half it does
  run — is green on the new files.

## Commits
c95c051 teardown fix; 8e7bae5 review; c811966 ledger; f3a7989 jit-down wait; b4ccdaa OPTS; 60f48e4 cold
tolerance; 9f72b30 voting-a alignment; then the docs and evidence for all of it (HEAD).

## Next step
Decide the volume-vs-password question, or retire the build plan's cold-start Done item naming that reason.

## Watch out
- Latent: `ipam.py` has no lock; `_allocated_ip` cannot tell a failed read from "no address"; a claim can sit
  `Ready` with no container (the stale-Ready detector needs the Secret to be gone).
- Untracked but referenced by README/todo/systemPatterns: `docs/jit-infra-poc.md`, `docs/jit-infra-flows.md`,
  `docs/01-jit-poc.md`, `docs/decisions/`.
