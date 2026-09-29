Updated: 2026-09-29

## Working
Nothing is being built. Stage H (S23-S29) was implemented by an autonomous overnight run
and is ticked; the open work is review, not implementation.

## Done (verified)
- S23-S29 done (both boxes ticked). Overnight run exit 0 at 07:56; 49 commits on `main`
  since `f39fb33`, tree clean.
- S29 gate green (`docs/evidence/S29.log`): U1-U13 live, `make jit-verify` J1-J11 PASS,
  `make verify NS=voting-a` 17 PASS / 0 FAIL.
- S23 spike measured (ADR 0007): replaces <=1s both modules, 50/50 queued votes lost on a
  redis replace, vote/worker reconnect, `call_runner` off-loaded by kopf. Verdict
  `maxmemory mutable` by human decision.
- Autonomy harness committed: `scripts/run-overnight.sh` (self-`caffeinate`, PASS/verdict
  gating, ADR-checkpoint enforcement, `IMPL_EXTRA` directives, morning report) and the two
  agent definitions.

## Broken (confirmed by execution)
- `scripts/checks/S18.sh:147` - "redis did not stay Ready - worker still references it"
  cannot pass while undeploy removes all three Deployments. It is frozen, so amending it
  needs the human's approval. (Unchanged since S22.)

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data
  directory, container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks
  fail; `ipam.py` has no lock.
- No gate covers volume removal on destroy any more; J6 asserts the volume stays.

## In progress
Nothing.

## Blocked
- The S18 redis assertion (see Broken) - awaiting the human.
- The stage boundary is not open: the cumulative stage review has not run, so Stage H is
  ticked but not accepted.

## Learnings
- An epic can be driven to green overnight by a shell orchestrator that gates on artefacts
  (evidence log PASS, findings verdict) rather than on a model's claim. The two-model split
  (implementer must differ from reviewer) is the part that catches real defects.
- The gate that matters is the reviewer's mutation test, not the checkpoint alone: it found
  a hand-written verdict and a stubbed-checkpoint hole that the checkpoint could not.
- A frozen checkpoint that only greps a log cannot prove the log was measured; a human
  decision (maxmemory mutable) is therefore recorded as an ADR, not as a measured verdict.
- 15 ADRs in one run is a smell: 10 were checkpoint amendments. `ADR 0005/0006` fixed four
  contract bugs in S22; the run found ~10 more, which says the Stage-H checkpoints were
  under-specified before the code existed.
- All verdicts were CONCERNS, never CLEAR. CONCERNS-with-no-blockers is a usable pass bar
  for an experiment but is weaker than the build plan's "CLEAR only".
- gnhf is a good engine but a poor fit here: its per-iteration contract requires a strict
  JSON final message, which a heavy OpenCode objective did not produce.
