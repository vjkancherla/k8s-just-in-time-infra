# 0020. S29 exposed three controller gaps: TTL maximum, create-path contract scope, appliedParams clearing

Date: 2026-09-29
Status: accepted

## Context

S29 is the gate that runs the design's U1-U13 against the live stack. Running it against the
S26-S28 controller exposed three behaviours the design requires but the code did not have:

1. **`softDeleteTTL` is the declared maximum (design §Resolution rules, rule 7).** S26's
   review recorded this as absent and parked it on S29/U13 ("`softDeleteTTL` maximum
   resolution (design rule 7) is absent from this step ... so rule 7 is not silently dropped
   before S28/S29 (asserted by U13)", `docs/reviews/S26-findings.md`). `reconcile_claim` never
   touched TTL; `spec.softDeleteTTL` was taken once from the creating event
   (`main.py:158`) and never re-derived, so annotating a second reference with a longer window
   changed nothing and U13 could not pass.
2. **The mutability contract was applied on the create path, so pgadmin's module-declared
   `http_port` was refused.** `validate_params` has an empty allowlist for `pgadmin` (the
   design's table: "pgadmin | any | Not assessed | Refused in v1"), and `reconcile_claim`
   called it before provisioning a brand-new claim as well as before an update. The
   `voting-b` overlay pins pgadmin's host port to 5051 through `params` (so two pgAdmins do
   not collide on 5050, S15 findings item 10), so its pgadmin claim was permanently
   `UpdateRefused` and never provisioned - `make jit-verify`'s J8, which requires all three
   `voting-b` claims Ready, could not pass. The design's own rule 3 is explicit that this is
   wrong: "On a new claim, first-writer-wins stays as today, so **create behaviour is
   unchanged**." And the contract's opening sentence scopes it to change: "which params may
   **change** and how".

3. **`status.appliedParams` could never shrink.** Every write went through
   `patch_status_fields`, whose JSON merge patch treats `{}` as "change nothing". So when a
   declarer changed back to the defaults (`{}`), `appliedParams` kept the old keys: the
   resync saw desired `{}` != applied, re-applied on every tick (a container-replace loop),
   and a later edit to the removed value was then judged "equal" and never applied. The
   merge-patch semantics, not the comparison, were wrong.

## Decision

Change `jit-controller/main.py` only, in two places:

- **Rule 7.** Add `_max_reference_ttl(namespace, module)`, which returns the raw
  `softDeleteTTL` string of the longest-declared window across every live reference
  (declarers and consumers alike), and patch `spec.softDeleteTTL` when it differs. It is a
  spec patch only - never a runner call - exactly as the design says.
- **Contract scope.** Call `validate_params` only when the claim is already provisioned
  (`phase` in `Ready`/`Orphaned`). A brand-new claim projects its desired params and
  provisions them as the module declares them; only an edit to provisioned infra goes
  through the per-module mutability table. The refusal assertions (U7, U8) run on existing
  claims and are unaffected; first create behaviour is what rule 3 requires it to be.
- **appliedParams clearing.** Add `patch_applied_params`, which reads the claim's current
  `appliedParams`, nulls the keys the new params drop, and sets the new ones in the same
  merge patch. Use it for the create, update and backfill writes.

## Consequences

**Easy.** U13 can pass: a longer TTL on any reference becomes the claim's window with no
runner call. The `voting-b` pgadmin claim provisions, so the J-suite's J8 and the rest of the
tenants' second namespace work as S17 left them. A new claim may carry the module's declared
parameters (the pgadmin `http_port` case) without the update contract rejecting it.

**Hard / ruled out.** The mutability contract no longer guards the *initial* application of a
new claim's params; an unknown key on a brand-new annotation reaches tofu (which only warns
on unknown `-var`s). That is the pre-S22 create behaviour rule 3 pins, and it is the price of
letting `pgadmin`'s module-declared port through; edits to a provisioned claim remain fully
refused. Rule 7's max is computed from the annotations on every reconcile - a spec write, no
runner call - and does not widen the mutable surface.
