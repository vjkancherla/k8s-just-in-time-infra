# 0018. S28's checkpoint asserts no Deployment declares redis; correct it to the design's table

Date: 2026-09-29
Status: accepted

## Context

`scripts/checks/S28.sh:44-45` asserts that the base's `vote` Deployment *consumes*
redis - that `role voting-app-vote redis` is `noparams` ("vote must CONSUME redis").
That contradicts the design it is supposed to assert:

- The design's migration table names redis's **declarer** as `voting-app-vote` and its
  **consumer** as `voting-app-worker`
  (`docs/designs/declarers-and-consumers.md:209-213`).
- `docs/build-plan.md:1013` (S28 **Do**) instructs exactly that: "Do the migration
  exactly as the design's table (redis: `vote` declarer, `worker` consumer; postgres:
  `worker` declarer, `result` consumer; pgadmin: `vote` declarer)".
- The checkpoint's own header says "the pairs checked are exactly the design's migration
  table" (`scripts/checks/S28.sh:16-18`), so the assertion contradicts its stated source
  as well.
- The S29 U-table is written against the same migration: U1, U5, U8, U9 and U10 all
  annotate `voting-app-vote` as *the redis declarer*
  (`scripts/checks/S29.sh:59, 151, 214, 243`).

Taken literally the frozen assertion leaves redis with **no declarer at all**: `worker`
is asserted to consume redis, and `vote` is asserted to consume redis too. Redis is the
one module with two references and no third Deployment, so under that shape a fresh
consumer-first namespace (design U6) could never converge past
`Pending`/`AwaitingDeclarer`, and the claim would never be provisioned.

The likely source is the build-plan invalidation row at `docs/build-plan.md:1002`, which
inverts the pair for redis ("declarers keep params (vote: pgadmin; worker: redis +
postgres); consumers lose the key (vote: redis; result: postgres)"). The operative design
table and the S28 **Do** agree with each other against that row.

Per the frozen-checkpoint protocol, a checkpoint may change only through an ADR committed
with the edit; this is that ADR.

## Decision

Amend `scripts/checks/S28.sh:44-45` only: `role voting-app-vote redis` must be
`declarer` - the annotation carries a `params` key - matching the design's migration
table. The failure message now reads "vote must DECLARE redis (params key present)".

No other assertion changes. The pairs the checkpoint checks after the edit are exactly
the design's table: `worker`: redis consumer, postgres declarer; `vote`: redis declarer,
pgadmin declarer; `result`: postgres consumer.

## Consequences

**What this makes easy.** S28 can migrate to the shape the design specifies: one declarer
per module, so redis is declared by `vote` (its enqueueing frontend) and consumed by
`worker`; postgres is declared by `worker` and consumed by `result`; pgadmin is declared
by `vote`. The checkpoint now asserts the design rather than the inverted plan row, and it
lines up with the S29 U-table that runs against the same base.

**What this makes hard / what it rules out.** The build-plan invalidation row at
`docs/build-plan.md:1002` is left stale for redis; `docs/build-plan.md` is not in S28's
Read/Do file list, so correcting it belongs to the orchestrator, not this step. The
assertion is not weakened: it still distinguishes `declarer` from `noparams` and still
fails on a missing annotation - only the expected value changes.

**Checkpoint provenance.** This ADR and the edit to `scripts/checks/S28.sh` are committed
together, before `scripts/checkpoint.sh 28` runs, as the runner requires. The S28 review
prompt cites this ADR so the reviewer judges the change against the design, not the frozen
file in isolation.
