# Infra settings-change flow - Team Brainstorm
Date: 2026-09-27
Reviewed: consilium 2026-09-27 - 1 blocker fixed (falsifiable acceptance criteria), 2 risks in Open questions
Team: Kira, Nova, Sage, Ivy, Remy, Ops (Milo swap for infra/platform)
Context read: jit-controller/main.py, jit-runner/main.py, deploy/crd/infraclaim.yaml, jit-modules/modules/redis/variables.tf, jit-modules/modules/postgres/variables.tf, docs/designs/jit-infra-flows.md, docs/designs/annotation-to-state.md, docs/designs/runner-api.md. Missing: docs/design/infra-change-flow-brainstorm.md claimed by memory-bank 2026-09-26; docs/design/ is empty on disk, so no prior decision constrained this run.
Full debate: [infra-change-flow-transcript.md](./infra-change-flow-transcript.md)

## Decision
Concept 1 (Converge) wins 5-1: the Deployment annotation stays the sole source of truth; the controller syncs `InfraClaim.spec` from it and re-applies via runner `POST /v1/runs`, with a new `Updating` phase, `status.observedParams`, and an advisory `AppRestartRequired` condition (controller never restarts app pods). v1 scope is `params` + `softDeleteTTL`; `moduleVersion` is deferred (runner ignores `version` today - modules are local files). What changed in consilium: acceptance criteria rewritten so every give-up sets a condition within one 30s resync tick.

## Concepts

### 1. Converge (annotation -> spec sync -> runner re-apply) *(selected)*
On Deployment create/update events plus the 30s resync (sourced: `@kopf.timer interval=30`), the controller diffs annotation params against `status.observedParams`. On drift it patches claim spec, sets phase `Updating`, re-POSTs the full param set (tenant params + name/ip/network + resolved `postgres_password`/`postgres_url`), and only on runner success patches Secret `jit-<module>` + Service + EndpointSlice and advances `observedParams`. Failures keep serving old outputs and set `Failed`/condition - never `Deleting`. Rollback is re-annotating the old value through the same path.
- **Pros:** Single tenant surface (annotations only, no second API); keeps IP + container name (`{ns}-{module}-{module}`) so safe tunes like `maxmemory` (default `256mb`, sourced from `variables.tf`) cause no connection drop; rollback is free.
- **Cons:** Real behaviour change in the hot path - runner `create_run` cache early-return (`jit-runner/main.py:210-214`) must be busted and controller Ready-skip (`main.py:299-306`) must compare params, not just presence; a 600s runner call (sourced: `call_runner timeout=600`) inside a kopf handler blocks other events unless offloaded; CRD `status` is a closed list so `observedParams` needs a CRD edit or the API server prunes it.
- **Effort:** M (~4-6 days: controller sync + phases + runner cache fix + CRD + checkpoint).
- **Touches:** `jit-controller/main.py` (`ensure_claim`, `provision_infra`, `resync_referenced_by`, `check_param_conflict`), `jit-runner/main.py` (`create_run`, `_apply_run`), `deploy/crd/infraclaim.yaml`, `jit-modules/modules/*/variables.tf` (safe-var inventory).

### 2. Recreate (destroy + create as the update)
Any param drift runs the existing `destroy_infra` + `cleanup_k8s_resources` + fresh `provision_infra` on the same IP. No runner apply semantics to debug; endpoint flaps exactly once.
- **Pros:** Reuses the proven destroy path; no cache-busting or new phases; trivially testable.
- **Cons:** Drops every connection on each tune; destroys postgres data by default (S17 rule: a container removal takes its volume); turns a `maxmemory` bump into downtime.
- **Effort:** S (~2-3 days).
- **Touches:** `jit-controller/main.py` (resync drift to destroy path).

### 3. Claim-as-API (spec edit, annotation frozen after bootstrap)
Operators edit `InfraClaim.spec.params` directly; the controller watches spec generation and re-applies. Annotations become bootstrap-only. RBAC gates tuning.
- **Pros:** One writer with real API semantics (`kubectl diff` works); sidesteps multi-Deployment param conflicts.
- **Cons:** Two sources of truth during migration; every Deployment apply must not stomp the edit (freeze logic nobody asked for); tenants learn a second object; breaks the annotation-as-lease model the resync depends on.
- **Effort:** M (~3-5 days + docs/RBAC).
- **Touches:** `jit-controller/main.py`, `deploy/controller.yaml` (RBAC), console read model.

### 4. Blue-green claim (new workspace, flip Service)
On drift, provision a `-v2` container on a fresh IP from the namespace block of 10, cut Service/EndpointSlice over on success, destroy the old. Instant rollback by flipping back.
- **Pros:** Only zero-downtime story for replace-type changes; the old container is the backup.
- **Cons:** Costs 2 IPs + 2 containers + 2 MinIO keys per update (block pressure assumed at 3+ parallel updates - assumed, no measurement); breaks the `{ns}-{module}-{module}` naming; vast overkill for scalar tunes.
- **Effort:** L (~8-12 days).
- **Touches:** `jit-controller/ipam.py`, `jit-controller/main.py`, `jit-runner/main.py`, `deploy/crd/infraclaim.yaml`.

## Debate highlights
- **Remy's premise challenge (is tuning even needed?):** Remy argued immutable infra + recreate was the PoC philosophy. *Answered:* team proceeds - the first `maxmemory` question kills the demo otherwise - but Remy's blast-radius point scoped v1 to safe params.
- **Sage vs Nova on the coupling unit:** Sage's claim-as-API lost to annotation-wins when Nova showed a Deployment re-apply would either stomp operator edits or let the annotation lie. *Synthesised:* annotation owns desired state, claim spec is a synced copy.
- **Ivy vs Ops on testability:** Ivy showed "patch Secret after success" asserts nothing when outputs are byte-identical (`maxmemory` changes no output). *Synthesised:* `Updating` phase + `observedParams` advancement is the assertion; failures keep old outputs, never `Deleting`.
- **Sage vs Ops on app restart:** agreed the controller never restarts tenant pods (privilege escalation); infra convergence (phase) and app staleness (condition) are two separate signals.

## Roads not taken
- **Recreate-is-the-update as the default** (raised by Ivy, conceded in part for stateful): strongest case was one code path and falsifiable tests. It lost because postgres data loss is the default path under the S17 volume rule. It would win if updates were stateless-only or an explicit `recreate` intent flag existed.

## Vote
| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | Only option where tenant never learns a second object. |
| Nova | 1 | Reuses create path; cheapest correct mechanism. |
| Sage | 1 | Annotation-wins + observedParams closes the two-writer hole I opened. |
| Ops | 1 | Keeps identity + Secret atomicity; recreate wipes data. |
| Ivy | 2 | Still thinks 1's "success" is untestable without a replace-refusal gate; 2 is the only falsifiable update. |
| Remy | 1 | Smallest shippable that answers the premise; ties break to scope. |

## Acceptance criteria (consilium-fixed: every give-up is falsifiable within one 30s tick)
1. Annotating a Ready claim with a new safe param (e.g. redis `maxmemory`) reaches `Updating`, then `Ready` with `observedParams` equal to the annotation, Secret/Service still present throughout.
2. A failed re-apply leaves the old Secret bytes servable, sets `Failed` or `Ready`+`UpdateFailed` condition with runner message, and never sets `Deleting` or clears the finalizer.
3. Re-annotating the prior value reconverges without manual cleanup (rollback = forward path).
4. Two Deployments sharing a claim with divergent params keep first-writer-wins behavior: `ParamsConflict` names winner and ignored writers within one resync tick.
5. Secret content change sets `AppRestartRequired=True` with message naming the claim; no Deployment rollout is triggered by the controller.
6. Orphan/TTL semantics unchanged: an update in flight with refs removed goes `Updating` -> `Orphaned` (or finishes then orphans); expiry still drives `Deleting` only from `Orphaned`.

## Open questions
- [ ] Safe-vs-destroy gate: static per-module allowlist (e.g. `maxmemory`, `postgres_db` excluded) vs inspecting tofu plan for replacement? (Ops, Sage - needed before postgres tunes ship)
- [ ] 600s apply blocks kopf handlers: offload re-apply to a thread/queue or accept the 30s resync as backstop with `Updating` stuck visible? (Nova, Ops)
- [ ] Does `Updating` need `status.paramSource` (which Deployment wrote the winning params) for the console, or is `observedParams` enough? (Kira, Nova)

## Next steps
- [ ] Add S22 (this note) to `docs/build-plan.md` + `docs/todo.md`, then implement controller spec-sync + update flow in `jit-controller/main.py` with `scripts/checks/S22.sh` covering the six criteria above (includes CRD edit for `observedParams`/`Updating`).
