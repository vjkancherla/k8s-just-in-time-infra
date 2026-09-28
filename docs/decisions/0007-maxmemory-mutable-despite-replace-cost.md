# 0007. Redis maxmemory stays mutable despite the replace cost

Date: 2026-09-28
Status: accepted

## Context

The S23 spike (`docs/evidence/s23-spike.log`, produced by the human-run protocol in
`docs/evidence/s23-spike.sh`) measured what the mutability contract may only claim after
measurement:

- a redis container replace completes in **<=1s** (tofu apply 0.79s + container start,
  measured as the wall time until redis answers again);
- a postgres container replace completes in **<=1s** (tofu apply 0.76s + server start,
  until `pg_isready`); the named `docker_volume` and its rows survived the replace;
- `vote` and `worker` reconnect to the recreated containers, and the worker drains a
  post-replace vote; and
- **50 of 50** queued votes were lost across the redis replace, because redis is the vote
  queue and `maxmemory` lives in the container `command`, so changing it replaces the
  container and empties it.

The contract's criterion 1 ("adds or tunes, never removes data") would refuse `maxmemory`
on the 50-of-50 loss alone, and the spike's own first reading did. The trailing verdict
line is therefore **not a number the probe produced**: it is the human decision recorded
below. `docs/evidence/s23-spike.log` states this next to the verdict.

## Decision

An infrastructure change made through the Deployment annotation is an explicit approval
for any downtime it causes, so downtime is accepted. The replaces are <=1s and both apps
reconnect, so the update cost is acceptable: **redis `maxmemory` stays in the mutable
surface and U1 stays in scope.**

The design's "refused" branch is not taken: no `declarers-and-consumers-v1-superseded.md`
v2 and no empty-allowlist fallback is written, and no design round follows. The trailing
`VERDICT: maxmemory mutable` line in `docs/evidence/s23-spike.log` is this decision, not a
result the probe measured.

## Consequences

**What this makes easy.** U1 (edit the redis declarer to `maxmemory: 128mb`; within one
tick the container command changes, `appliedParams` matches, IP and existing Secret bytes
unchanged) is a real, buildable update. S24's params-keyed cache and S26's contract can
treat redis `maxmemory` as mutable rather than a permanently refused key. The measured
<=1s replace and the reconnect observations bound the downtime the tenant has explicitly
approved by editing the annotation.

**What this makes hard / what it rules out.** A `maxmemory` change drops every queued,
not-yet-drained vote; a declarer editing it accepts that loss, and the module docs and the
console must say so. This supersedes the spike's criterion-1 *refused* reading for redis
`maxmemory` only: removing a database, renaming `postgres_db` or changing the password
remain refused (U7), and the v1 mutable surface is not otherwise widened. The verdict is a
recorded decision, so a reviewer must judge this ADR - whether its reasoning is sound and
its scope correct - rather than re-derive mutability from the probe's timings; the probe
alone cannot settle it.
