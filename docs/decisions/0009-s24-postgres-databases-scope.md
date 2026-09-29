# 0009. S24 scope: the postgres `databases` variable is declared in S24, wired in S27

Date: 2026-09-29
Status: accepted

## Context

The S24 checkpoint `scripts/checks/S24.sh` (frozen; amended by ADR 0005 and ADR 0008)
creates a postgres workspace to exercise the destroy path's conditional `state rm`.
Its postgres create POST includes `"databases":["voting"]` (`scripts/checks/S24.sh:60`).
OpenTofu 1.8.1, on the host and in the runner image, refuses a `-var` the module does
not declare — `Error: Value for undeclared variable` — so the frozen checkpoint cannot
pass unless `jit-modules/modules/postgres/variables.tf` declares `databases`.

S24 implemented that declaration (`list(string)`, default `[]`) and ADR 0008 recorded
the adaptation. The S24 review (`docs/reviews/S24-findings.md`, 2026-09-29) returned
BLOCKED on Blocker 1: a mechanical rule-4 finding. `jit-modules/modules/postgres/` is
S27's territory (`docs/build-plan.md` S24's scope names `jit-runner/`, not
`jit-modules/`), so S24 had quietly consumed S27's file. The review's recorded remedy is
a scope decision, not a revert: reverting the declaration turns the frozen checkpoint
red, and a third checkpoint edit is not available without another ADR.

## Decision

`jit-modules/modules/postgres/variables.tf` is in S24's scope for the single
`databases` variable (`type = list(string)`, `default = []`). S24 declares it so the
frozen checkpoint's create can succeed; S27 wires it to `postgresql_database` resources
and must not re-declare it (ADR 0008 records the same split). No other `jit-modules/`
path is in S24's scope, and no assertion changed.

## Consequences

**Easy.** The S24 review's rule-4 blocker is resolved without a third checkpoint edit;
the frozen checkpoint stays exactly as ADR 0005 and ADR 0008 left it. The S24 review
prompt's scope list names the file, so a later reviewer can see the decision rather than
rediscover the edit as creep.

**Hard / ruled out.** S27's ownership of the postgres module narrows to the
`postgresql_database` wiring for `databases`; it inherits the variable rather than
declaring it. Reverting the declaration is ruled out: the checkpoint's postgres create
would fail with an undeclared-variable error and the destroy path would go untested.
