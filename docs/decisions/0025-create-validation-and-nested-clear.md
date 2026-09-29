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
  provisioned, and **before** projecting desired onto `spec.params`, so a refused key never
  lands there. Identity/controller-owned keys are still refused everywhere, and `http_port`
  is validated as a port (integer 1-65535).
- **Deep clearing.** A shared `_merge_patch(old, new)` builds a merge patch that nulls
  removed keys at every depth; `patch_applied_params` and `_project_spec_params` both use
  it.

The authority for create validation is the contract table, not rule 3: design line 112
("a key the module does not declare | Unknown | Refused; tofu only warns on unknown
`-var`s, so a typo would be recorded as applied") and line 114 ("values are validated before
any runner call"). Rule 3's "create behaviour is unchanged" is scoped to *disagreeing
declarers* and says nothing about which keys are accepted.

This supersedes ADR 0020's Decision bullet "Call `validate_params` only when the claim is
already provisioned" and its create-scope consequence ("the mutability contract no longer
guards the initial application of a new claim's params"). The create surface is not every
declared variable - pgadmin's `share_dir`, `postgres_port`, `pgadmin_email` and
`pgadmin_password`, and postgres's `service_name`, are controller-supplied rather than
tenant settings - only the tenant-settable subset.

## Consequences

- A brand-new claim with an unknown or typo'd key is refused (`UpdateRefused`, reason
  `RefusedKey`) instead of being recorded as applied. pgadmin's `http_port` still
  provisions, so `voting-b` and the J-suite's J8 are unaffected. Changing `http_port` on a
  provisioned pgadmin claim remains refused (the update contract is unchanged).
- A refused create no longer has its desired *projected* onto `spec.params` by
  `reconcile_claim`, but that does **not** close the teardown leak: `ensure_claim` seeds
  `spec.params` from the annotation at claim creation (`main.py` ~154-160, ~210), before any
  validation, and no `appliedParams` is ever written, so `_destroy_params`
  (`appliedParams or spec.params`) still returns the refused key and the destroy retries
  every tick while the claim holds its IP. This matches the pre-diff behaviour (a typo'd
  create always ended this way), so it is pre-existing debt, not a regression; the real fix
  is to sanitise `_destroy_params` against `validate_params`, which is not done here. The
  cumulative review (`docs/reviews/session-debt-cumulative-findings.md`) found this claim
  false; this bullet is the correction.
- A nested `settings` key that is dropped now clears from `appliedParams` and
  `spec.params`, so the resync stops re-applying and a later re-add is a real change.
- `S26` (controller core, stub runner) is the gate: it creates redis claims with
  `maxmemory`/no params and asserts the update refusals, which the create allowlist
  preserves. S29's U7/U8 refusal assertions run on provisioned claims and are unaffected.
- The create allowlist is a second place a module's surface is named; a new module param
  must be added there as well as to the module. It is deliberately the small, declared
  surface, not "anything".
