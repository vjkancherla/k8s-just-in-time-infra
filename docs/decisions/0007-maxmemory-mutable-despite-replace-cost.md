# 0007. Redis maxmemory stays mutable despite the replace cost

Date: 2026-09-28
Status: accepted

## Context

The S23 spike (`docs/evidence/s23-spike.log`, produced by the probe in
`docs/evidence/s23-spike.sh`) measured what the mutability contract may only claim after
measurement:

- a redis container replace completes in **<=1s wall time** (0.84s total in the recorded
  run: 0.77s tofu apply + 0.07s until redis answers again on the same IP);
- a postgres container replace completes in **<=1s wall time** (0.90s total: 0.83s tofu
  apply + 0.07s until `pg_isready`); the named `docker_volume` and its rows survived the
  replace;
- **50 of 50** queued votes were lost across the redis replace, because redis is the vote
  queue and `maxmemory` lives in the container `command`, so changing it replaces the
  container and empties the queue; and
- reconnect after a replace is only partly exercised. The worker is deliberately stopped
  to hold the queue, so its reconnect is a **fresh-pod startup** - its in-place
  `RedisError` reconnect path (`app/worker/app.py`) is *not* exercised, because the pod is
  recreated. `vote` stays up and reaches the new container through a **fresh per-request
  client** (`app/vote/app.py`) - reachability, not survival of a long-lived connection.

Those are **container-replace wall times only** (tofu apply plus time until the service
answers again on the same IP), measured on one warm host in one recorded run. They
deliberately exclude the controller noticing the annotation (up to the 30s resync), runner
queueing, and client retry - the parts a tenant actually waits through. Read the ADR as
"seconds", not "a one-second outage", whenever U1's tolerance is quoted in S26/S29.

The spike also settled the event-loop question: `call_runner` is a synchronous
`requests.post` (timeout 600s) inside a synchronous kopf handler, and kopf runs sync
handlers on an executor thread (the probe reports `separate executor thread: True`), so it
does not block the event loop and the 30s resync keeps ticking while an apply runs. The
executor is shared, though: kopf's default pool measured `max_workers=6`, shared by
`handle_deployment`, the 30s resync timer and the delete handler. The resync keeps ticking
only below that ceiling; at six concurrent 600s applies the resync queues behind the pool,
which is the same stop the design describes arriving through the pool rather than the
event loop. S26 decides whether to cap concurrency or move `call_runner` to
`asyncio.to_thread`; this ADR does not.

The contract's criterion 1 ("adds or tunes, **never removes data**",
`docs/designs/declarers-and-consumers.md:100`) read literally would refuse `maxmemory` on
the 50-of-50 loss. The trailing `VERDICT:` line in the log is therefore **not a number
the probe produced**: it is the human decision recorded below, and the log states this
next to the line.

## Decision

An infrastructure change made through the Deployment annotation is an explicit approval
for any downtime it causes, so downtime is accepted. The replaces are <=1s and the worker
reconnects on restart, so the update cost is acceptable: **redis `maxmemory` stays in the
mutable surface and U1 stays in scope.**

The design's "refused" branch is not taken: no `declarers-and-consumers-v1-superseded.md`
v2 and no empty-allowlist fallback is written, and no design round follows. The
`VERDICT: maxmemory mutable` line in `docs/evidence/s23-spike.log` is this decision, not a
result the probe measured.

## Consequences

**What this makes easy.** U1 (edit the redis declarer to `maxmemory: 128mb`; within one
tick the container command changes, `appliedParams` matches, IP and existing Secret bytes
unchanged) is a real, buildable update. S24's params-keyed cache and S26's contract can
treat redis `maxmemory` as mutable rather than a permanently refused key. The measured
<=1s replace and the worker's startup reconnect bound the downtime the tenant has
explicitly approved by editing the annotation.

**What this makes hard / what it rules out.** A `maxmemory` change drops every queued,
not-yet-drained vote; a declarer editing it accepts that loss. The in-place worker
reconnect path is not exercised by this spike, so "a running worker survives a replace
without a restart" is **not** established - only that a fresh worker pod starts against the
recreated container. The executor-pool ceiling above is likewise recorded, not measured
under load, and is S26's to resolve. This supersedes the literal criterion-1 *refused*
reading for redis `maxmemory` only: removing a database, renaming `postgres_db` or
changing the password remain refused (U7), and the v1 mutable surface is not otherwise
widened.

**Scheduling (so the code and the design cannot disagree).** `docs/designs/` is read-only
in S23, so this ADR - not the design note - is the authority until S28. S26 must implement
`maxmemory` as mutable (U1) and must not take criterion 1's "refused" branch. S28's
invalidation table must gain a row amending `declarers-and-consumers.md:100` (criterion 1)
and the stale "the step 0 spike confirms which case applies" line at `:161`; the table at
`:105` already lists `maxmemory` mutable with "queue contents lost". Recording the loss in
the module docs belongs to S28. The console is deliberately untouched by Stage H
(`docs/build-plan.md` S28's row: "no change ... **Deliberately untouched**"), so this ADR
creates **no** console obligation.

The build plan's S26 **Read** list cites design §Mutability contract and not this ADR, and
`docs/build-plan.md` is outside S23's named file list (rule 4), so S23 cannot wire the two
together. Before S26 starts, ADR 0007 must be added to S26's reading: S26's contract
otherwise codes criterion 1's literal "never removes data" (`declarers-and-consumers.md:100`)
and would refuse `UpdateRefused` on exactly the key U1 requires to be applied. This is an
orchestrator action on the plan, recorded here so it is not missed.

**Side finding carried forward (S27, not measured for this decision).** The probe also
recorded that every re-apply of the *stock* redis and postgres modules plans a container
replacement even with unchanged params: `ports { external = 0 }` records the random host
port in state and the next plan diffs `external = <assigned> -> 0 # forces replacement`
(`docs/evidence/s23-spike.log`). This is not a `maxmemory` fact and was not measured for
this decision, but it collides with S27/U2 ("`analytics` added ... container ID unchanged"):
S27 must pin or ignore the host port in the module, or every apply replaces the container.
It is recorded here because the 550-line spike log is where a later step will not look.

The verdict is a recorded decision, so a reviewer must judge this ADR - whether its
reasoning is sound and its scope correct - rather than re-derive mutability from the
probe's timings; the probe alone cannot settle it.
