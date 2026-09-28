# Infra Change Flow - Team Brainstorm

Date: 2026-09-26
Team: Kira, Nova, Sage, Ivy, Remy, Ops (SRE)
Context read: jit-controller/main.py (all 1007 lines), docs/designs/annotation-to-state.md, docs/designs/jit-infra-flows.md, docs/designs/runner-api.md, deploy/crd/infraclaim.yaml, jit-modules/modules/{redis,postgres,pgadmin}/variables.tf, docs/decisions/0001-0004, memory-bank/systemPatterns.md, docs/todo.md
Full debate: [infra-change-flow-transcript.md](./infra-change-flow-transcript.md)
Reviewed: consilium 2026-09-26 - 1 blocker fixed (falsifiable acceptance criteria), 2 risks in Open questions

## Decision

**Concept 1 - Converge (spec sync + re-apply).** The annotation remains the sole desired state: on a Deployment update event (and, as a backstop, on the 30s resync tick), the controller syncs `InfraClaim.spec` from the *paramSource* Deployment's annotation and, on drift, re-applies the module through the existing runner `POST /v1/runs` (tofu apply converges - in-place where possible, replace where forced), rewrites Secret/Service/EndpointSlice, and returns the claim to Ready through a new `Updating` phase. Rollback is the annotation itself: re-annotate, and the next reconcile converges back.

Scope cut from the premise challenge: v1 covers `params` + `softDeleteTTL`. `moduleVersion` is deferred - the runner ignores it (local modules), and shipping a knob the platform doesn't act on is a lie with a UI. The requirement itself stood up to the challenge (transcript, Phase 2).

## Acceptance criteria

1. In a Ready namespace, a param change via annotation on the paramSource Deployment converges: the claim shows `Updating`, then `Ready`; `make state` shows the new param; the timeline (S21) records both transitions. If the event is missed, convergence happens within one resync tick (30s - main.py L815).
2. Round trip: reverting the annotation converges the infra back, no manual teardown.
3. A param change from a non-paramSource writer does not change `spec.params`; a `ParamsConflict` condition names it.
4. Every give-up (runner error, missing paramSource, normalization mismatch) sets a claim condition within one resync tick - no silent no-op path.
5. `allocatedIP` and the Secret's `service_host` are unchanged across a change.
6. A `softDeleteTTL`-only change updates the spec without a runner call.

## Concepts

### 1. Converge (spec sync + re-apply) *(selected)*
Spec sync from the paramSource annotation (event + 30s resync backstop), re-apply via the existing runner `POST /v1/runs`, new `Updating` phase, `status.paramSource`, conditions on every give-up.
- **Pros:** single source of truth (ADR 0001 intact); self-healing; no runner changes; rollback = re-annotate.
- **Cons:** a second state machine atop orphan/TTL (silent-no-op surface); replace-forcing changes wipe data with no warning; a 600s runner call blocks kopf handlers.
- **Effort:** M (~3-4 days, assumed)
- **Touches:** jit-controller/main.py, deploy/crd/infraclaim.yaml, scripts/checks/S22.sh (new), docs/build-plan.md, docs/todo.md, docs/designs/jit-infra-flows.md, docs/designs/annotation-to-state.md, app/docs/MANUAL-TESTING-GUIDE.md

### 2. Reclaim (destroy-and-recreate on change)
On drift, Deleting → re-Pending: destroy the module, keep the IP, re-apply with the new params.
- **Pros:** both halves proven (S10-S17); unambiguous "a change is a new infra"; uniform, documented data loss.
- **Cons:** every change destroys state (heavy for a knob); downtime gap (pgadmin → dead postgres); a failed destroy = zombie-claim territory.
- **Effort:** S (~1-2 days, assumed)
- **Touches:** jit-controller/main.py, docs

### 3. Update API (imperative)
Editing the annotation stages; an explicit verb (make target/console action) applies.
- **Pros:** one explicit, auditable verb; no drift-detection state machine; trivially testable.
- **Cons:** two sources of truth in practice; the console allowlist is frozen by the S18 check; missed runs are silent no-ops in the other direction.
- **Effort:** S-M (~2-3 days, assumed)
- **Touches:** Makefile/console allowlist, jit-controller/main.py (spec sync only), docs

### 4. Version Bump (immutable identity)
A `moduleVersion`/`configHash` bump changes identity; the controller destroy + re-applies on mismatch.
- **Pros:** zero drift logic; matches the K8s immutable convention; deterministic.
- **Cons:** in-place-updatable knobs become data-loss; `configHash` is a drift detector in disguise; `moduleVersion` is ignored by the runner today.
- **Effort:** S (~1-2 days, assumed)
- **Touches:** jit-controller/main.py, annotation convention + docs

## Debate highlights
- **Remy's premise challenge** ("a tenant wants a bigger sandbox, not a setting change"): conceded on the merits - the demo story is one namespace changing (Kira), `maxmemory` is a real knob (Ops), and a postgres_db change is not expressible as a new namespace without data loss (Sage). Won with a scope cut: params + TTL only, `moduleVersion` deferred.
- **Ivy/Nova/Sage on authorship**: first-writer-wins has no recorded writer, so a drift check has no anchor. *Resolved:* `status.paramSource` + explicit re-resolution (source deleted → lexicographically-first survivor) + a condition on the authorship change.
- **Kira vs Ops on app cutover**: a controller-initiated rolling restart of referencing Deployments lost on blast radius ("a new privilege"). *Resolved:* advisory `AppRestartRequired` condition + doc line; auto-restart → open question.
- **Sage vs Remy on rollback**: the pre-change snapshot lost - "the annotation is the rollback". Conceded, with Ops's constraint that a failed update never enters Deleting.
- **Ivy's silent-no-op class**: *resolved* into acceptance criterion 4 - every give-up sets a condition within one resync tick.

## Roads not taken
- **InfraClaim.spec as the tenant form** (the Phase 3 coupling-unit alternative): the strongest case was that a typed CR field beats annotation JSON for ergonomics and validation. It lost because it re-litigates ADR 0001 (authoring on the Deployment) and turns the console's read-model surface into a write surface. It would win if tenants started managing infra outside manifests.
- **Last-writer-wins authorship** (raised by Ivy in Phase 2, killed in the paramSource synthesis): the strongest case was that it matches the tenant's mental model - "I just edited it, so it applies". It lost because event order isn't durable across a controller restart - the resync backstop would need a deterministic tie-break, and "last event" is not recoverable from a list of Deployments. It would win if the controller persisted an event log.

## Vote
| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | Annotate-and-done, reversible, visible in the timeline. |
| Nova | 1 | Reuses the create path; the resync backstop is S12-proven. |
| Sage | 1 | Only concept with an observable in-flight state; paramSource makes authorship a fact. |
| Ivy | 3 | The explicit verb is testable; 1's drift state machine is where the silent no-op lives. |
| Remy | 2 | 2 ships in two days on proven paths; 1's extra logic is PoC tax I don't see yet. |
| Ops | 1 | 1's failures stay in Ready/Failed territory; 2 routes every change through the zombie-prone Deleting path. |

## Open questions
- [ ] Should a change that forces a container replace (data loss) be gated behind an explicit acknowledgement (e.g. `acceptDataLoss` in params)? v1 behaviour: document it. (Ivy)
- [ ] Controller-initiated rolling restart of referencing Deployments when the Secret changes (vs the advisory condition). (Kira)
- [ ] `paramSource` re-resolution when the source Deployment is deleted: verify interaction with `ParamsConflict` before S22; if it grows, it pends to S23. (Ivy)
- [ ] A 600s runner call (main.py L488) inside a kopf handler blocks other cluster events while an update runs (assumed: single handler queue). Mitigation: the update runs under the claim lock; the resync is the backstop; revisit if the demo shows event lag. (Ops)
- [ ] `moduleVersion` changes: defer until the runner fetches modules from a git ref. (Nova)

## Next steps
- [ ] Add an S22 step to docs/build-plan.md: drift detection + spec sync + `Updating` phase + S22 checkpoint script covering acceptance criteria 1-3 (round trip, two-writer conflict, TTL-only change).
- [ ] In the same step, update docs/designs/jit-infra-flows.md (change sequence diagram + state-machine line) and docs/designs/annotation-to-state.md (spec-sync section).
- [ ] Update app/docs/MANUAL-TESTING-GUIDE.md: how-to + app-restart caveat.
