# S28 Review

Reviewer model: deepseek-v4-pro
Verdict: CONCERNS

## Blockers

None.

## Concerns

1. **The build plan still contradicts itself on the redis declarer, and it is left live in the repo.** `docs/build-plan.md:1002` (invalidation table) says consumers "lose the key (vote: redis; result: postgres)" and declarers "keep params (vote: pgadmin; worker: redis + postgres)" — i.e. it asserts `vote` *consumes* redis and `worker` *declares* redis. That is the exact inverse of the S28 **Do** at `build-plan.md:1013-1015` and of the design's migration table (`declarers-and-consumers.md:209-213`), both of which name `vote` as redis declarer and `worker` as consumer. The implementation, the checkpoint (post-ADR 0018), and the S29 U-table all follow the design table, so the implementation is correct — but `build-plan.md` now carries two directly opposing instructions for the same step. ADR 0018 documents this ("left stale for redis … correcting it belongs to the orchestrator"), so I do not treat it as a blocker against the implementer: `build-plan.md` is not in S28's file list and the ADR handled the frozen-checkpoint side correctly. It is, however, a live contradiction in the build plan that must be fixed by the orchestrator before S28 is closed, or the next reader of the invalidation table will migrate redis the wrong way.

2. **`jit-infra-poc.md:74` annotation example is missing `moduleVersion`.** The diff rewrote this line to `'{"module":"redis","params":{"maxmemory":"128mb"},"softDeleteTTL":"30d"}'`, moving `maxmemory` inside `params` and adding `module`, but left out `moduleVersion`. Every other annotation example in the same document and in the design note (`declarers-and-consumers.md:63-68`) carries both `module` and `moduleVersion`, including the tenant-surface example the same diff fixed a few lines down (`jit-infra-poc.md:134`). A tenant copying line 74 verbatim would produce an annotation the schema otherwise never shows. Trivial to fix and purely illustrative, so it does not stop a merge — but the diff touched this exact line and fixed it only halfway.

## Notes

- The migration shape in the three base manifests is exactly the design's table: `vote` declares redis and pgadmin (`params:{}`), `worker` declares postgres and consumes redis (no `params`), `result` consumes postgres. All three declarers use `params:{}`, so before-and-after resolve to the same defaults and no apply runs — the migration is correct by construction.
- The checkpoint's section 5 (`tofu fmt -check` on `jit-modules/modules/postgres` and `redis`) asserts nothing S28 changed: this step touched no module files. It is named in the build-plan checkpoint ("`tofu fmt -check` on the affected modules") so it is sanctioned, but it is a formatting sanity check with no bearing on this step's goal.
- The committed `docs/evidence/S28.log` records `commit ce43c87` (the ADR commit) with 8 pending changes, which matches the flow: ADR + checkpoint edit committed first, manifests/docs edited, checkpoint run, then everything (including the log) committed as `310a18a`. The log is a genuine capture, not a typed PASS.
- The doc greps in section 4 of the checkpoint are loose (`grep -q "params"`, `grep -qiE "declarer|consumer"`). They pass for the right reason now, but they would not catch a regression that kept the string while deleting the semantic content. Low severity; noted, not blocking.

## Checkpoint assessment

`scripts/checkpoint.sh 28 /tmp/S28-review.log` passes cleanly on the current tree (exit 0, 0 uncommitted changes), and the result matches the committed evidence. The checkpoint does assert the step's goal: the `role()` parser derives declarer/consumer from the presence of the `params` key in the built manifests and checks each pair in the design's migration table; the `git grep -l '"params"'` scan fails if `result` regains `params` or if the declarers lose them; and the four doc greps verify the drift fixes. If the `params` key were removed from every declarer the `role()` checks fail (worker postgres, vote redis, vote pgadmin would all report `noparams` instead of `declarer`), and if `result-deployment.yaml` regained `params` the grep scan fails — so the checkpoint is not a no-op. The one caveat is inherent to the step's static nature: "no apply runs / both resolve to the same desired params" is asserted only as a manifest shape, and the runtime proof (backfill, no container replace) is S29's U-table, not this checkpoint.

Verdict: CONCERNS
