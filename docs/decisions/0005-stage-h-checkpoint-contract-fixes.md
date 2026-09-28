# 0005. Stage-H checkpoint contract fixes after the S22 review

Date: 2026-09-28
Status: accepted

## Context

Stage H's seven child checkpoints (`scripts/checks/S23.sh`-`S29.sh`) were written in the
S22 pre-flight and frozen at `d0d4329` (the rebuilt history's S22 commit; the first
re-review's `a1bafed` named the pre-rebuild commit the rebuild removed). The build plan's
rule and `.clinerules/01-jit-poc.md` both say a checkpoint that turns out to be wrong is
**not** edited to match the code - it is raised as a design question. Three rounds of
S22 review found that several frozen checkpoints assert contracts no correct
implementation can satisfy, or that the machinery which produces S22's only record can
certify a run that never happened. The human directed "docs/reviews/S22-findings.md -
there are more blockers, review and fix"; this ADR is the written decision that sanctions
those edits, is committed with them, and is cited in `docs/build-plan.md` Stage H and the
S22 review prompt. Per `docs/decisions/0000-template.md`, it records what forced the
decision, what was chosen, and what it rules out.

## Decision

Change, through this decision, exactly the assertions and harness bugs listed below. Each
fix is a mechanics correction to the contract, not a softening: every one still fails
readably with nothing implemented and can go green once S23-S29 are built.

### S23.sh - verdict parsing

Asserted: after requiring a `VERDICT: maxmemory (mutable|refused)` line, `case
"$verdict_arg" in *maxmemory*) fail` — since `verdict_arg` came from that line, the guard
always fired and S23 could never pass.

Now asserts: the verdict is matched again into exactly `VERDICT: maxmemory mutable` or
`VERDICT: maxmemory refused`; anything else fails. Passing either way still requires the
measured evidence (timings, vote loss, reconnect, blocking verdict) and now can go green
when the spike produces the verdict the regex demands.

### S24.sh - the destroy assertions

Asserted: a redis-only workspace (`s24-check`) whose destroy must log `state rm`. The
design makes `tofu state rm postgresql_*` conditional on the run's state containing
`postgresql_*` resources; a design-conforming implementation never runs it there, so the
assertion demanded unconditional execution.

Now asserts both sides of that conditional, per build-plan S24's bullet 3:

1. identical re-POST → cached success, one container (unchanged);
2. changed params → real re-apply, command updated (unchanged);
3. destroy the redis workspace → **no** `state rm`, container gone (the conditional's
   negative side, previously asserted as its opposite);
4. create a postgres workspace (`databases=["voting"]`), `docker rm -f` its container,
   then destroy → succeeds (the refresh-fails-without-state-rm trap), and **no**
   `${name}-postgres-data` volume survives (the plan bullet the first script asserted
   nowhere).

### S26.sh - the conflict and update groups

1. Group 2's guard was `[ -z "$(stub_get ...)" ] && fail`, which cannot fire (the
   provisioning POST from group 1 is already in the log) and, if it fired, would report
   the opposite of the truth. Now asserted the design way, like group 4: runner-call
   count captured before the disagreeing declarer, asserted unchanged after
   `ParamsConflict=True`.
2. Group 5 re-declared the exact params group 1 applied (`maxmemory: 200mb`), which the
   design's update flow step 1 ("Equal: stop") forbids to POST; the group would have
   failed a correct controller. It now declares `maxmemory: 222mb` - a value that
   differs from `appliedParams` - and expects the apply to reach the stub and record
   `appliedParams.maxmemory = 222mb`.
3. The `cleanup` trap dereferenced `CTRL_PID` before it was assigned, printing
   `CTRL_PID: unbound variable` on the step's own precondition-failure path. It now
   uses `${CTRL_PID:-}`.

### S29.sh - the precondition and U12

1. Lines 26-27 ran `kubectl get … 2>/dev/null` and then `|| fail` under `set -euo
   pipefail`; the bare kubectl failure killed the shell before `fail` printed, so a
   deployed-app cluster missing the demo exited with no readable reason. Now an `if !
   kubectl …` guard, which keeps the script alive long enough to name the precondition.
2. U12's phase read (`Terminating` is not `Active`) registered a deletion still in
   flight, then `kubectl get ns && fail "wedged finalizer"` accused correct code of
   wedging a namespace that legitimately still listed during cleanup. Now asserted
   against the completed state: the namespace read must come back gone and stay gone
   for the checks that follow (claims survive check, finalizer check, container check).
3. The three kubectl-calling steps' preconditions, and `S26.sh`'s `cleanup` trap, were
   previously unbounded: against a dead or black-holed API server the precondition
   itself, and the trap's scale-back, hit a connection that never returns, wedging the
   checkpoint (demonstrated: S26 hung past 240s before this fix). Every kubectl call now
   runs through a bound helper (`kk` = `kubectl --request-timeout=5s`), so a
   precondition failure is a fast, readable `FAIL:` - in a S26 trap as well as the
   preconditions of the three steps that call kubectl.
4. The first cut of the `kk` helper in item 3 was itself a bug: it renamed the inner
   `kubectl` to `kk`, making the helper recurse infinitely - the bash child died with
   SIGSEGV (exit 139) instead of returning a readable FAIL.
   `kk() { kubectl --request-timeout=5s "$@"; }` calls the real binary.

### S26.sh - the `-g` typo

The group-5 loop read `[ "$n1" -g "$n0" ]`. `-g` is not a test operator: every pass
printed `binary operator expected`, and the loop never broke early, so a conforming
controller took the full 90s wait instead of breaking on the tick the update landed. It
is `-gt`.

### S26.sh - the `cleanup` trap's `kill 0`

The trap still wedged after group 2's guard fix. The reading blamed
`[ -n "${CTRL_PID:-}" ] && wait`; that line was a bug too (it evaluates false on the
precondition-failure path, returns 1, and under an EXIT trap re-triggers exit before
`exit "$rc"`), but the actual hang was one line up: `kill "${CTRL_PID:-0}"` and
`kill "${STUB_PID:-0}"`. With the variable unset the parameter default yields the literal
`0`, and `kill 0` signals **the whole process group** - the checkpoint's own shell
included - which then hangs waiting on itself. In the batch this presented as S26 hanging
until the 240s watchdog (and, before the watchdog, an hour-long stuck run). Both kills and
the wait now use the non-failing, non-group-signaling form
`[ -z "${CTRL_PID:-}" ] || kill "$CTRL_PID"` (likewise `STUB_PID` and the `wait`), so the
trap reaches its `exit "$rc"` and S26 fails readably in ~0.1s.

### The pre-flight harness - two files named

Two files the first cut did not name are now part of S22 and sanctioned here:
`scripts/s22-all-fail.sh` (the summary is *derived* by re-running the seven through
`scripts/checkpoint.sh` and reading the captured logs, so the summary is typed in no
script) and `scripts/checks/lint-helpers.sh` (a guard against the two
runaway-execution shapes this stage has already hit - the `kk` recursion and unbounded
wait loops; run first by the summarizer). Both carry a readable `FAIL:`/`PASS` and exit
non-zero on failure.

### The pre-flight harness - the freshness gate

`scripts/s22-all-fail.sh` could certify a run the runner refused. It ran each checkpoint
with stdout discarded and then read `docs/evidence/SNN.log`; when `scripts/checkpoint.sh`
refuses before truncating the log (a dirty checkpoint is a stop trigger), the old log was
read and scored as this run's failure. Demonstrated in a scratch clone: with one comment
appended to `scripts/checks/S27.sh`, the builder printed S27's stale `FAIL:` from the
committed log and ended `PASS … exit 0`. Now the runner's own output is kept, and the log
is trusted only when its `# started` is at or after this run's start; a refused or stale
log is reported from the runner's words and fails the pre-flight. This is round-1 blocker
3's class (evidence not tied to an executed run) reappearing inside the sanctioned tool.

### S29.sh - the first precondition

S29's first line piped `make state` into `json.load`; an empty document (e.g. the
untracked `deploy/.env` missing) raised and, under `set -euo pipefail`, exited 1 with a
bare traceback and no `FAIL:` line. The readable-`FAIL:` contract applies to the *first*
thing the script runs, not just the `kk` guards below it. Now `make state` is read into a
variable with failures consumed and a bad document reaches a named `fail`. Demonstrated:
with `.env` moved aside, S29 printed `FAIL: make state did not report up=True (got '') -
run 'make demo-up' before this checkpoint`.

## Consequences

**Easy.** The seven child checkpoints now assert contracts a correct implementation can
satisfy and fail readably on a fresh checkout; S26 and S29 no longer hang or die on their
own preconditions; the all-fail record cannot be produced from a run the runner refused.
Intent is recoverable from this document without re-deriving it.

**Hard / ruled out.** `scripts/checks/` gains no further edits without a new ADR. The
edits are committed with this decision and cited in the review prompt; a step that
extends its own scope list without an ADR remains the thing `.clinerules/01-jit-poc.md`
rule 4 exists to stop. Two ordering wrinkles are left as debt, not blockers: `bcedbd6`
edited `S29.sh` one commit before the ADR text landed in `88004d4`, and the S23/S24
contract fixes sit inside `d0d4329`, the commit this document calls the freeze point.

**Not in scope.** The concerns the reviews also raised - S29 U7's `postgres_db` variant,
U1's Secret-byte check, U3/U13's timestamps, S24's name/log coupling - stay unfixed:
the protocol fixes blockers, concerns go back to the next design round.
