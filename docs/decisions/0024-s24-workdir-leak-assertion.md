# 0024. S24 asserts the runner work-dir does not leak

Date: 2026-09-29
Status: accepted

## Context

ADR 0023 debt 1 names an unbounded work-dir leak: every changed-params apply overwrote
`_runs[key]` without removing the replaced run's directory (~61 MB each; the S24 reviewer
measured six orphans). The fix (`7a15db8`) removes the replaced directory, and an
independent review verified it live. But the S24 checkpoint could not see it:
`scripts/checks/S24.sh` never inspected `/tmp`, and the review proved that deleting the
removal still printed the same `PASS`. A checkpoint that passes with the logic it exists to
protect deleted asserts nothing - the exact defect the stage-H review template's Q7 exists
to catch.

## Decision

Amend the frozen `scripts/checks/S24.sh`, sanctioned by this ADR: after the changed-params
re-apply, assert that exactly one `/tmp/jit-s24-check-*` directory exists in the
`jit-runner` container; after the destroy, assert there are zero. The count is read with
`docker exec jit-runner` - available wherever S24 already runs, since its precondition is
the runner container and `docker`.

## Consequences

- Removing the leak fix now fails S24, so the fix is gated by the checkpoint rather than
  resting on a review's ad-hoc `/tmp` probe.
- S24 gains a dependency on the runner's work-dir naming (`jit-<workspace>-*`, the runner's
  own `mkdtemp` prefix). A rename there breaks this check loudly, which is the intended
  failure direction.
- The separate `delete_run`-is-unlocked race (the review's concern 2, ADR 0023 debt 1) is
  **not** covered by this amendment. It makes this new removal able to pull a directory out
  from under an in-flight destroy, and it needs its own reviewed step.
