# 0010. S24 checkpoint amendment: assert the identical-params cache hit

Date: 2026-09-29
Status: accepted

## Context

S24's goal has two halves: a changed params hash is a real run, and identical params
are the cached success (`docs/build-plan.md` S24: "A changed params hash is a real run;
the old behaviour stays for identical hash"). `scripts/checks/S24.sh` asserts the first
(test 2: a changed `maxmemory` moves `Created` and the container command) but not the
second. Test 1 re-POSTs identical params and asserts only `status == "success"` and one
container; it never compares `Created` across the re-POST, so a runner with the success
cache deleted entirely still passes every assertion.

The S24 review (`docs/reviews/S24-findings.md`, Concern 1) recorded exactly this gap and
its remedy — "add `created_after_identical == created1` to test 1" — through an ADR
because the checkpoint is frozen.

## Decision

Amend test 1 of `scripts/checks/S24.sh` to capture `Created` after the identical
re-POST and assert it equals `Created` before the re-POST. No other assertion changes;
nothing is removed or weakened.

## Consequences

**Easy.** The checkpoint now fails if the success cache is removed: an identical re-POST
would re-apply, replacing the container and moving `Created`. Both halves of the goal
are asserted, and test 2 still pins the params-keyed change detection.

**Hard / ruled out.** `scripts/checks/` gains one further edit, only with this ADR; a
later change requires another. The checkpoint's exit semantics and its PASS line are
unchanged. The cache-hit assertion is meaningful only because the checkpoint's first
create populates the cache before the identical re-POST: if the cache were bypassed the
container would be replaced and `Created` would move.
