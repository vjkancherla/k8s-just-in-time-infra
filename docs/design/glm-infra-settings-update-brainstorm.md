# Tenant infra settings-change flow - Team Brainstorm
Date: 2026-09-27
Reviewed: consilium 2026-09-27 - 2 blockers fixed (observedParams records tenant annotation params only, never controller-resolved credentials; tick bounds added to criteria 1 and 4), 2 risks recorded in Open questions
Team: Kira, Nova, Sage, Ivy, Remy, Ops (Milo swap for infra/platform)
Premise challenge: Remy
Context read: jit-controller/main.py, jit-runner/main.py, deploy/crd/infraclaim.yaml, jit-modules/modules/redis/main.tf, jit-modules/modules/redis/variables.tf, jit-modules/modules/postgres/main.tf, jit-modules/modules/pgadmin/variables.tf, docs/designs/annotation-to-state.md, docs/designs/runner-api.md, docs/designs/jit-infra-flows.md. Excluded per the user's instruction: the prior spark-infra-change-flow-* notes in docs/design/ (fresh run).
Full debate: [infra-settings-update-transcript.md](./infra-settings-update-transcript.md)

## Decision
Concept 1 (Converge) wins 4-1-1: the Deployment annotation stays the sole source of truth. The controller diffs the winning annotation's params against a new `status.observedParams` on Deployment events and the 30s resync; on drift it syncs `spec.params` to the annotation, sets phase `Updating`, and re-POSTs the full param set to runner `POST /v1/runs` (whose success-cache must learn to compare params, not just presence). It re-writes Secret/Service/EndpointSlice only after a verified apply, advances `observedParams`, and returns to `Ready`; a failed apply goes back to `Ready` with an `UpdateFailed` condition (old outputs keep serving, no auto-retry). v1's updatable-param allowlist is exactly `redis.maxmemory` - every other param gets `UpdateRefused` naming the param, because the debate established that redis's only tune is a tolerable container replace (same IP, no volume) while every postgres env change silently diverges the Secret from the container's actual state.

## Concepts

### 1. Converge (annotation -> spec sync -> runner re-apply) *(selected)*
Drift detection on Deployment create/update events plus the 30s resync (sourced: `@kopf.timer interval=30`, `jit-controller/main.py:815`). Diff winning-annotation params vs `status.observedParams` (new status field - the CRD's status list is closed and prunes unknown fields, so `deploy/crd/infraclaim.yaml` needs the field added; `phase` itself is a free string, so the new `Updating` phase value needs no CRD edit). `observedParams` records the tenant's ANNOTATION params only - never the controller-resolved credentials (`postgres_password`, `postgres_url`), which would publish a secret into claim status, readable by anyone who can `get infraclaims`. On drift: patch `spec.params` from the annotation (spec stays a synced copy - `check_param_conflict` first-writer-wins keeps working), set `Updating`, re-POST the full param set (tenant params + `name`/`ip`/`network` + controller-resolved credentials) to the runner. Only on `status: success` re-write Secret/Service/EndpointSlice (even when byte-identical), advance `observedParams`, set `Ready`. Failure: `Ready` + `UpdateFailed` with the runner message - old Secret bytes keep serving, the finalizer stays, `Deleting` is never set, no resync auto-retry (matches the create-path contract: a Deployment change re-fires). Non-allowlisted param drift: `UpdateRefused` condition naming the param, nothing applied. Secret content change: advisory `AppRestartRequired` condition naming the claim - the controller never restarts tenant pods (env vars resolve at container start; the pods are stale until the tenant rolls them). Rollback is re-annotating the prior value through the same path.
- **Pros:** single tenant surface - annotations only, no second API; IP and container name preserved (`var.ip` in `networks_advanced` survives the tofu replace); rollback is free; the resync's lease/orphan model is untouched because the spec stays a synced copy.
- **Cons:** two hot-path behavior changes at once - the controller's Ready-skip (`main.py:299-306`) must compare params, and the runner's success cache (`jit-runner/main.py:209-214`) must compare params or every converge is a silent no-op; a 600s synchronous `call_runner` (sourced: `main.py:488`) inside a kopf handler, with `Updating` visible as the mitigation; every allowed tune is actually a container replace with a listening gap (redis: reconnect, no data); `observedParams` requires a CRD schema edit or the API server prunes it.
- **Effort:** M (~5-7 days: controller drift/phase/conditions, runner cache fix, CRD edit, `scripts/checks/S22.sh`, jit-infra-flows.md state-machine update - estimate, not a measurement).
- **Touches:** `jit-controller/main.py` (`handle_deployment`, `provision_infra`, `resync_referenced_by`, `check_param_conflict`), `jit-runner/main.py` (`create_run` cache), `deploy/crd/infraclaim.yaml`, `docs/designs/jit-infra-flows.md`, `scripts/checks/S22.sh`.

### 2. Recreate-is-the-update
Any param drift runs the existing `destroy_infra` + `cleanup_k8s_resources` + fresh `provision_infra` on the same IP. No new phases, no cache fix, no CRD edit.
- **Pros:** one code path and it is the tested one; zero new runner semantics; the whole assertion is "the endpoint comes back on the same IP".
- **Cons:** pays the full destroy window for every tune, including refused ones; for postgres it is the Secret/container divergence trap with extra steps (volume survives, env ignored on the old data dir, Secret rewritten wrong); no record of which params are applied; sits in the same blast radius as the undeploy demo's S18 assertion.
- **Effort:** S (~2-3 days; estimate).
- **Touches:** `jit-controller/main.py` (resync drift detection wired to the destroy path).

### 3. Claim-as-API
Operators edit `InfraClaim.spec.params` directly (RBAC-gated); the annotation is bootstrap-only; the controller watches spec generation and re-applies.
- **Pros:** real API semantics - `kubectl diff` on the thing being changed; RBAC is free Kubernetes; no JSON-in-a-string.
- **Cons:** two sources of truth during migration; every Deployment re-apply must not stomp the edit (freeze logic nobody asked for); tenants learn a second object; breaks the annotation-as-lease model the resync depends on.
- **Effort:** M (~3-5 days plus RBAC and console work; estimate).
- **Touches:** `jit-controller/main.py`, `deploy/controller.yaml` (RBAC), console read model.

### 4. Plan-gated converge
Concept 1 with the gate moved from a static allowlist to tofu itself: the runner runs `tofu plan`, parses the plan JSON, refuses any apply that replaces a volume-owning resource.
- **Pros:** the gate is grounded in tofu's actual behavior rather than a hand-maintained list; new modules inherit it automatically; mechanically catches the postgres divergence class.
- **Cons:** needs a plan endpoint or a two-phase plan-then-apply call in the runner (kills the no-new-endpoint constraint); plan JSON is a moving schema; asserting on plans in CI needs a live docker provider; doubles the apply cost per update.
- **Effort:** L (~8-12 days; estimate).
- **Touches:** `jit-runner/main.py` (plan endpoint or two-phase), `jit-controller/main.py`, `deploy/crd/infraclaim.yaml`.

## Debate highlights
- **Remy's premise challenge (is tuning needed at all?):** immutable infra would ship nothing, and the frozen S-checks all assert things stay Ready. *Answered:* the codebase already promises changeable params (`check_param_conflict`, sourced: `main.py:646-675`) and the console invites edits it silently ignores - proceed, with the v1 surface at exactly one param.
- **Ivy vs Ops on what "in-place" means:** `maxmemory` is in the container command, ForceNew for the docker provider (sourced: `redis/main.tf:30`) - the marquee safe tune REPLACES the container. *Synthesised:* "safe" means replacement is tolerable (stateless or volume survives), not that nothing is replaced.
- **Sage + Ivy vs Ops on postgres updates:** env changes against an existing volume get written into the Secret and ignored by the container - a password rotation that leaves the old password working. *Synthesised:* postgres has no updatable params in v1; rotation needs `ALTER USER`, inexpressible in tofu-docker.
- **Ivy vs Ops on testable success:** byte-identical outputs make Secret-byte assertions vacuous. *Synthesised:* `observedParams` advancement is the assertion; the `Updating` phase closes the lying-Ready window during the 600s apply.
- **Nova vs Sage on two sources of truth:** spec-as-API always loses to the annotation on Deployment re-apply - annotation wins and the edit is stomped, or spec wins and the annotation lies. *Conceded by Sage - candidate for Roads not taken.*

## Roads not taken
- **Claim spec as the desired-state owner** (raised by Sage, conceded in Phase 2): the strongest case was real API semantics - `kubectl diff`, RBAC, no JSON-in-a-string. It lost because the annotation is also the keep-alive lease, and any tenant Deployment re-apply must either stomp the edit or let the annotation lie. It would win if tenants ever stopped writing annotations - an operator-only platform where claims are provisioned once by tooling and tuned forever after.
- **Per-Deployment updates instead of per-claim** (rejected at the coupling-unit step): each annotating Deployment would converge the shared container itself. Lost immediately - two writers, one container name, exactly the race `claim_lock` and the runner's `_run_lock` exist to end.

## Vote
| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | The tenant surface never grows; the console stops lying about edits it ignores. |
| Nova | 1 | Reuses the create path end to end; the runner diff is five lines, not an API. |
| Sage | 1 | With `UpdateRefused` the divergence trap is closed by default, not by discipline. |
| Ops | 1 | Identity (IP, name, Secret) survives every update; failed updates touch nothing live. |
| Ivy | 2 | Concept 1's success signal is testable now, but the Updating window is still underobserved in a 600s blocking handler; 2 has exactly one moving part. |
| Remy | 2 | Smallest shippable answer to the premise; if the one-knob allowlist is the whole feature, destroy+recreate is the same feature with less machine. |

4-1-1 to Concept 1. Unmade case recorded: nobody priced a SECOND annotation change arriving during a 600s `Updating` window - the resync cannot start what it cannot see, and the next tick's params diff would re-enter an in-flight update (Remy should have made it; see Open questions).

## Acceptance criteria (every give-up sets a condition within one 30s resync tick)
1. Annotating a Ready redis claim with `maxmemory: 512mb` reaches `Updating` within one tick of the annotation change, then `Ready` within one tick of the runner success, with `status.observedParams` equal to the annotation params; Secret/Service/EndpointSlice remain present throughout; the replaced container comes back on the same IP (endpoint unchanged).
2. Annotating any claim with a non-allowlisted param (e.g. postgres `postgres_db`) sets `UpdateRefused` within one tick naming the param and the refusing module; phase stays `Ready`; Secret bytes and `observedParams` unchanged.
3. A failed re-apply (runner error) leaves the old Secret bytes serving, sets `Ready` + `UpdateFailed` with the runner message within one tick, and never sets `Deleting` or clears the finalizer.
4. Re-annotating the prior value reconverges without manual cleanup within the same tick bounds as criterion 1 - rollback goes through the same path as forward.
5. Two Deployments sharing a claim with divergent params keep first-writer-wins: `ParamsConflict` names the winner and the ignored writers within one tick (existing behavior preserved).
6. A Secret content change sets `AppRestartRequired=True` naming the claim; no tenant Deployment rollout is triggered by the controller (Deployment generation unchanged).
7. Orphan/TTL semantics unchanged: refs removed during an in-flight update ends in `Orphaned` within two ticks (or the update finishes and then orphans); `Deleting` is still reached only from `Orphaned` or namespace deletion.

## Open questions
- [ ] Queued second update: an annotation change arriving while `Updating` (600s window) - queue it, coalesce to the latest, or refuse with a condition until the first converges? (Remy, Nova - needs an answer before the S22 check for criterion 1 can be written)
- [ ] Offload the 600s runner call out of the kopf handler, or accept the block with `Updating` visible and the 30s resync as crash-recovery backstop? (Nova, Ops)
- [ ] Plan-gated converge (Concept 4) as the v2 replacement for the static allowlist - worth a runner plan endpoint, or does the allowlist scale fine for a three-module demo? (Sage, Ops, Ivy)
- [ ] Does the console need `status.paramSource` (which Deployment wrote the winning params), or is `observedParams` enough? (Kira, Nova)
- [ ] Post-apply liveness is unobservable by the controller: an apply with a garbage value (`--maxmemory banana`) returns green and the container crash-loops - Ready claim, dead endpoint. Accept as a documented PoC limit, or add a container-health probe to the runner? (Ivy, Ops)

## Next steps
- [ ] Add S22 (this note) to `docs/build-plan.md` and `docs/todo.md`.
- [ ] CRD edit first: add `status.observedParams` (object, `x-kubernetes-preserve-unknown-fields: true`) to `deploy/crd/infraclaim.yaml` - nothing else in the flow is testable until the field survives the API server.
- [ ] Implement the controller drift/phase/condition machine in `jit-controller/main.py` and the runner cache params-compare in `jit-runner/main.py`.
- [ ] Write `scripts/checks/S22.sh` covering the seven acceptance criteria above. Inject criterion 3's runner failure at the HTTP boundary (unreachable runner / stub returning `status: error`), NOT via an invalid param value - tofu applies those green and the container crash-loops afterwards, which is not an apply failure.
- [ ] Document the updatable-param allowlist where tenants will look (console read model or module docs) - the mechanism is general but the v1 surface is one param, and an undocumented refusal reads as a bug.
- [ ] Update the claim state machine in `docs/designs/jit-infra-flows.md` in the same step the behavior changes (that doc's own rule).
