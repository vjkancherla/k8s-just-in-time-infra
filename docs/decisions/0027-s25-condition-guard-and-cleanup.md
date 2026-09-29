# 0027. S25 restores its status probe; the controller checks condition types before patching

Date: 2026-09-29
Status: accepted

## Context

Two items from the stage review's S25 concern (`docs/reviews/STAGE-H-findings.md` item 8,
carried in `docs/HANDOFF.md` P0.6):

1. **`conditions.type` is a closed enum.** `set_condition` patches the whole
   `status.conditions` array at once. The CRD's enum (`deploy/crd/infraclaim.yaml`) admits
   only seven types; if any element carries an out-of-enum type the API server rejects the
   entire patch, and the handler catches the `ApiException` and logs only a warning. One
   stray type therefore silently drops *every* condition write in that call. No current
   type is out of enum, so nothing is broken today - it is a guard against the next edit.
2. **S25 leaves residue.** The checkpoint's round-trip probe patches the first live
   claim's `status.appliedParams` to `{"probe":"s25"}` (plus `attemptedParamsHash` and
   `declaredBy`) and never restores it. A live claim then holds a probe value as its applied
   result (it defeated the backfill precondition on that claim by construction; U11 later
   backfills over it).

## Decision

- Add `_CONDITION_TYPES` to `jit-controller/main.py` (the same seven the CRD enum lists) and
  have `set_condition` log an error and return when `cond_type` is not in it, rather than
  patching an array the server will reject wholesale. `clear_condition` is unaffected.
- Amend the frozen `scripts/checks/S25.sh`, sanctioned by this ADR: (a) snapshot the
  round-trip claim's `status` before the probe and restore `appliedParams`,
  `attemptedParamsHash` and `declaredBy` from it after the assertions, nulling the probe key;
  (b) assert every CRD enum type also appears in the controller's `_CONDITION_TYPES`, so the
  two lists cannot drift (the controller guard is only safe while they match).

## Consequences

- A type the controller does not expect is refused loudly (error log) instead of dropping the
  whole condition array; valid types are unchanged.
- S25 leaves the claim's status as it found it, so a gate run no longer poisons a live
  claim's `appliedParams`.
- The controller's list is now asserted against the CRD by a checkpoint; adding a condition
  type requires editing both, and S25 fails loudly if only one is updated.
- No assertion in S25 is weakened; the cleanup runs after the existing pruned-field checks.
