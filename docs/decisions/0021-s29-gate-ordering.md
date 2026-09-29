# 0021. S29 gate ordering: J-suite first, no demo-mode toggle

Date: 2026-09-29
Status: accepted

## Context

ADR 0019 made the S29 suite gate turn `ALLOW_MULTIPLE_VOTES` off before
`make verify NS=voting-a` and back on afterwards, because `make demo-up` leaves the demo
toggle on and R3 asserts the one-vote-per-browser behaviour. Running the gate for real
showed the toggle is racy: `kubectl set env` starts a vote rollout, and the immediately
following `kubectl rollout status` returned success before the new pod was serving, so the
R-suite hit the still-restarting Ingress and failed `R1 code=502` (and `R2/R5/R6/R8`) while
the app recovered in time for the later checks. The run's own captured log records
`U1-U11, U13` all `ok` and the gate failing on `===== 12 PASS, 5 FAIL =====`; a manual rerun
with the pod confirmed Ready gives `17 PASS, 0 FAIL`.

## Decision

Change the gate in `scripts/checks/S29.sh`: **run `make jit-verify` first, then
`make verify NS=voting-a`**, and remove the `ALLOW_MULTIPLE_VOTES` toggle from the gate.

The J-suite resets and redeploys both tenants itself (`verify-jit.sh`'s `reset_ns` +
`apply_ns`), and its J9 restore leaves voting-a freshly applied from the base manifest with
`ALLOW_MULTIPLE_VOTES=false` and the vote Deployment Ready. Running verify on that stable
stack is the mode R3 asserts, with no environment change and no rollout to race. Both
suites still run before U12 deletes voting-a; the J-suite's own J2 already runs R1-R17 on
that fresh stack, and the explicit `make verify` re-confirms it.

The EXIT trap's `ALLOW_MULTIPLE_VOTES=true` restore stays - it returns the cluster to the
demo state after the run.

## Consequences

**Easy.** The gate no longer depends on a rollout settling between `set env` and the first
R-check; it is deterministic on a freshly deployed stack. It still fails readably if either
suite breaks, and it still runs both before U12.

**Hard / ruled out.** The gate now resets voting-a before the R-suite, so `make verify`
tests the J-suite's restore state rather than the U-test mutations - which is the
build-plan's intent ("both suites must survive everything Stage H changed"), not a loss.
ADR 0019 item 4's toggle is superseded by this ordering; the rest of ADR 0019 stands. Any
further S29 change needs another ADR.
