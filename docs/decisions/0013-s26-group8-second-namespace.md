# 0013. S26 group 8: a second scratch namespace instead of recreating the first

Date: 2026-09-29
Status: accepted

## Context

[ADR 0012](0012-s26-checkpoint-harness-fixes.md) item 5 fixed group 8's
nonexistent claim locator by recreating the first scratch namespace
(`jit-stub`) before the consumer-only scenario: delete the namespace, wait for it
to go, recreate it, apply the consumer, then assert a genuinely new
`Pending` + `AwaitingDeclarer` claim.

The first run of the amended `scripts/checkpoint.sh 26` (captured at commit
`4ef154f`, `docs/evidence/S26.log`) passed groups 1-7 and then failed:

```
Error from server (AlreadyExists): object is being deleted: namespaces "jit-stub" already exists
FAIL: scratch namespace recreation failed
```

The namespace was still `Terminating` after the delete's 60s wait plus a
further 60s polling loop. The cause is in the harness, not the controller: the
local controller is started with `WATCH_NAMESPACES` (ADR 0012 item 6), and a
namespace-scoped watch does not deliver the claim's delete to the operator while
that namespace terminates. The claim's `jit.infra/teardown` finalizer therefore
stayed put; the namespace could not complete; the recreate hit `AlreadyExists`.
No `Hard delete` or `Deleted claim` line appears in the run's controller log,
and the namespace only cleared after the checkpoint's trap scaled the in-cluster
controller back to 1.

## Decision

Give groups 8 and 9 a second scratch namespace, created up front, instead of
recreating the first. Concretely, in `scripts/checks/S26.sh`:

- define `NS=jit-stub` and `NS2=jit-stub-consumer`;
- create both namespaces before the controller starts;
- start the controller with `WATCH_NAMESPACES="$NS,$NS2"`;
- in group 8 set `NS="$NS2"` before applying the consumer, so the groups' claim
  locator, `waitcond`, `waitfield` and `make` all name the second namespace;
- the cleanup trap deletes `jit-stub` and `jit-stub-consumer` explicitly
  (the single `"$NS"` delete would leak the first after the reassignment).

The group 8 and 9 assertions are unchanged: consumer-only → `AwaitingDeclarer`
and `Pending`, declarer → `Ready`, then the stale `Updating` recovery. Only
which namespace holds the claim changes. No namespace is deleted mid-run, so no
finalizer is on the path.

## Consequences

**Easy.** Group 8 no longer depends on a controller finalizer removing while a
namespace terminates: the second namespace exists from the start and the claim
is genuinely new. The first seven groups' state is untouched, which the run
showed passes. The confinement of ADR 0012 item 6 is preserved (both scratch
namespaces are watched; no tenant namespace is).

**Hard / ruled out.** `scripts/checks/S26.sh` gets a second amendment, so
`docs/evidence/S26.log` must be regenerated again and the review prompt cites
ADR 0012 and this ADR for Q1/Q3/Q4. ADR 0012 item 5's namespace-recreation
approach is superseded by this one; the rest of ADR 0012 stands.

**Not in scope.** No assertion text changed; no controller behaviour changed.
The `NS` reassignment is a harness detail, and the cleanup names both scratch
namespaces so neither leaks.
