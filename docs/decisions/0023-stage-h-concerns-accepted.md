# 0023. Stage H review boxes stand on "no blockers"; the stage review's concerns are accepted as debt

Date: 2026-09-29
Status: accepted

## Context

Stage H (S22-S29) was implemented in an autonomous overnight run. Each step was reviewed by
a model that did not implement it; every verdict was CONCERNS with an empty Blockers
section, and the steps were ticked under the orchestrator's bar - "the loop is complete with
no blockers" - set by explicit human direction.

A cumulative stage review by an independent model (Muse Spark, which neither implemented nor
wrote the per-step findings) returned BLOCKED. The blocker is procedural, not technical:
the tracker ticks `review` boxes on CONCERNS while `docs/build-plan.md:15-21` requires a
different model to write a literal CLEAR, and no recorded decision sanctioned the looser bar.
The same review confirmed the implementation has **no technical blocker** - all ten
checkpoint amendments fix genuine harness/contract bugs (several strengthen the gate), the
cold S29 gate passes (U1-U13, `make verify` 17 PASS, `make jit-verify` J1-J11), and ADR 0007
is sound and correctly scoped - and raised twelve concerns.

## Decision

1. **The S23-S29 review boxes stand.** The human set the bar for this stage to "no blockers";
   this ADR records that direction so the tracker is not asserting an unsanctioned state.
   CONCERNS with an empty Blockers section is accepted for Stage H. This is deliberately
   weaker than the build plan's "CLEAR only" and is recorded as a stage-scoped deviation.
2. **S22's `review` box is ticked.** S22's findings already read CLEAR and its CONCERNS were
   resolved by decision in ADR 0006; leaving it unticked while S23-S29 were ticked was an
   inconsistency, not a standard.
3. **`docs/build-plan.md:1002` is corrected** to the design's migration table - `vote` is the
   redis declarer and `worker` its consumer, `worker` the postgres declarer and `result` its
   consumer, `vote` the pgadmin declarer. The implementation, the S28 Do, the amended S28
   checkpoint and the S29 U-table already agreed; only this invalidation row was inverted.
4. **The stage review's twelve concerns are accepted as recorded debt**, below. None blocks
   the stage; the highest-value fixes are named for the next work rather than attempted
   blind immediately after a stage-level BLOCKED.

### Accepted debt (reviewer's ranking, not fixed here)

- **Runner (concern 7):** every changed-params POST leaks a ~61 MB work dir (`_runs[key]`
  overwritten without `rmtree`) - unbounded disk growth, now reachable on every update; a
  `state list` failure silently degrades to "no `postgresql_*`" and proceeds into the destroy
  S24 exists to prevent; the `postgresql_` filter is prefix-only; `delete_run` is unlocked;
  `runner-api.md` documents neither the params-keyed cache nor the destroy-params type.
  *(attack #1/#2)*
- **Controller (concern 3):** `patch_applied_params` clears only top-level removed keys, so a
  dropped nested `settings` key survives and the resync re-applies every tick.
- **Controller (concern 2):** the create path provisions unvalidated, so an unknown/typo'd
  key is silently recorded as applied; the "refuse unknown keys" guard holds only on update.
- **Gate (concern 4):** U13's postgres half is vacuous (`|| true`); only the redis half
  asserts rule 7's TTL maximum. Frozen S22 shape, untouched by any amendment.
- **Design prose (concern 1):** ADR 0016's `setsubtract` substitution left
  `declarers-and-consumers.md:170`'s `for_each` import requirement unamended.
- **Evidence hygiene (concern 6):** the committed `S29.log` was captured against a dirty
  tree; mitigated by two clean re-runs that pass.
- **Carried (concerns 8-12):** the S25 `conditions.type` enum drop risk and checkpoint
  residue; the S26 coverage gaps (new-declarer-after-a-gap, simultaneous disagreeing
  declarers, the "consumer adds agreeing params" half of rule 5); the S27 double-produced
  `service_url` and unencoded-password `service_url_<db>`; the post-gate stack not being
  demo-ready (U12 destroys `voting-a`); and `make test-up` exiting non-zero cold for a
  pre-existing `app/scripts/verify.sh` `VOTE_URL` bug outside this stage.

## Consequences

- Stage H is accepted, and its tracker is now truthful about the bar under which it was
  accepted. A reader of `docs/todo.md` can follow the link from the tick to this ADR.
- The debt list above is the input to the next work. The runner workdir leak and the
  `state rm` silent-skip are the first two items, ahead of any new stage.
- Future stages must either meet "CLEAR only" or record the same kind of deviation before
  their boxes are ticked.
