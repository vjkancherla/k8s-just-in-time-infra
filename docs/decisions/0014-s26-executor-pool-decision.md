# 0014. S26 executor-pool decision: keep the synchronous handlers, document the bound

Date: 2026-09-29
Status: accepted

## Context

[ADR 0007](0007-maxmemory-mutable-despite-replace-cost.md) measured the handler
question the design's §Crash recovery leaves open. `call_runner` is a
synchronous `requests.post` (timeout 600s) inside a synchronous kopf handler, and
kopf runs sync handlers on an executor thread, so the runner call does not block
the event loop and the 30s resync keeps ticking. The executor is shared, though:
kopf's default pool measured `max_workers=6`, used by `handle_deployment`, the
30s resync timer and the delete handler. At six concurrent 600s applies the
resync queues behind the pool - the design's stop, arriving through the pool
rather than the event loop. ADR 0007 records this and says: "S26 decides whether
to cap concurrency or move `call_runner` to `asyncio.to_thread`; this ADR does
not."

## Decision

Neither is applied in this PoC. The synchronous handlers stay, and the bound is
recorded as accepted:

- kopf already runs the sync handler off the event loop, so the design's
  `asyncio.to_thread` remedy applies only to an **async** handler - the spike
  established the sync-handler case, so the design does not require the move.
- the ceiling is reached only by six concurrent 600s applies. The demo has at
  most six claims (three modules x two namespaces), applies are serialised per
  claim by `claim_lock`, and the S23 spike measured real replaces at <=1s; a
  normal apply holds a worker for seconds, not the 600s timeout. The PoC's
  measured concurrency does not reach the bound.
- a concurrency cap implemented inside the sync handlers (a semaphore) would
  block the very workers it means to free, so it does not fix the ceiling; the
  real fix is to move the call off kopf's pool, which means converting the
  handlers to async, a change this step's Do list does not name.

A production deployment should either raise kopf's executor size or make the
blocking path async (then `asyncio.to_thread` puts it on asyncio's larger
pool). That is recorded here rather than built, because it is not needed to pass
S26 and would move code the step does not ask for.

## Consequences

**Easy.** S26's checkpoint and its result are unaffected; the ceiling is a
recorded, bounded risk rather than an open item. Anyone raising it has the
numbers (6 workers, 600s cap, six claims) and the two options in one place.

**Hard / ruled out.** The trigger to revisit is a real workload with more
simultaneous long applies, or a runner that hangs. Until then the sync handlers
are the deliberate choice. This ADR resolves ADR 0007's delegated decision; it
does not change `jit-controller/main.py`.

**Not in scope.** No handler conversion, no pool sizing, no runner changes. The
maxmemory mutability ADR 0007 decides is untouched.
