# 0025. Params are validated on the create path too; a merge patch clears nested keys

Date: 2026-09-29
Status: accepted

## Context

Two accepted-debt items from ADR 0023 (`docs/HANDOFF.md` P0.3, concerns 2-3):

1. **Create path unvalidated.** ADR 0020 moved `validate_params` behind `if provisioned:`
   so a brand-new claim could carry pgadmin's module-declared `http_port` (the voting-b
   overlay pins 5051). The accepted consequence was explicit: "an unknown key on a
   brand-new annotation reaches tofu (which only warns on unknown `-var`s)". A typo in a
   *creating* annotation is therefore silently recorded as applied - `status.appliedParams`
   says the param took effect when the module ignored it.
2. **Nested keys never clear.** `patch_applied_params` (and its sibling
   `_project_spec_params`) nulled only the *top-level* keys the new params dropped. A JSON
   merge patch treats `{}` as "change nothing", so a nested `settings` key that disappeared
   (`{"settings": {"work_mem": ...}}` -> `{"settings": {}}`) survived in `appliedParams`.
   The resync then saw applied != desired and re-applied on every tick (a
   container-replace loop), and a later edit to the dropped key was judged "equal".

## Decision

Change `jit-controller/main.py` only:

- **Create validation.** `validate_params` gains `on_create`, selecting between two
  allowlists: the update contract (unchanged: redis `maxmemory`, postgres
  `databases`/`settings`, pgadmin none) and a create surface that is the same plus
  pgadmin's `http_port`. `reconcile_claim` validates on every path, not only when
  provisioned. Identity/controller-owned keys are still refused everywhere, and
  `http_port` is validated as a port (integer 1-65535).
- **Deep clearing.** A shared `_merge_patch(old, new)` builds a merge patch that nulls
  removed keys at every depth; `patch_applied_params` and `_project_spec_params` both use
  it.

This supersedes ADR 0020's create-scope consequence ("the mutability contract no longer
guards the initial application of a new claim's params"). Rule 3's "create behaviour is
unchanged" is read as "the module's declared params are applied as given on create" - not
"any key is applied"; the create surface encodes exactly the declared params.

## Consequences

- A brand-new claim with an unknown or typo'd key is refused (`UpdateRefused`, reason
  `RefusedKey`) instead of being recorded as applied. pgadmin's `http_port` still
  provisions, so `voting-b` and the J-suite's J8 are unaffected. Changing `http_port` on a
  provisioned pgadmin claim remains refused (the update contract is unchanged).
- A nested `settings` key that is dropped now clears from `appliedParams` and
  `spec.params`, so the resync stops re-applying and a later re-add is a real change.
- `S26` (controller core, stub runner) is the gate: it creates redis claims with
  `maxmemory`/no params and asserts the update refusals, which the create allowlist
  preserves. S29's U7/U8 refusal assertions run on provisioned claims and are unaffected.
- The create allowlist is a second place a module's surface is named; a new module param
  must be added there as well as to the module. It is deliberately the small, declared
  surface, not "anything".
