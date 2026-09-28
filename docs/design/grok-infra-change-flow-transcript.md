# Infra settings change - Brainstorm Transcript
Date: 2026-09-27
Team: Kira, Nova, Sage, Ivy, Ops, Remy
Premise challenge: Remy
Context read: jit-controller/main.py (ensure_claim 409 no-op, provision_infra Ready+Secret skip, check_param_conflict first-writer-wins, resync interval=30, call_runner timeout=600), jit-runner/main.py (POST /v1/runs success-cache ignores params, tofu timeout=600), deploy/crd/infraclaim.yaml (status is a closed property list), jit-modules/modules/redis/{main.tf,variables.tf} (maxmemory default 256mb, in container command), jit-modules/modules/postgres/{main.tf,variables.tf} (postgres_password controller-owned, docker_volume managed, remove_volumes=false), docs/designs/annotation-to-state.md, docs/designs/runner-api.md, docs/designs/jit-infra-flows.md, docs/decisions/0001-annotation-on-deployment-ownership-on-namespace.md, docs/designs/jit-infra-poc.md (first writer wins), app/kustomize/base/vote-deployment.yaml, docs/design/ (empty — memory-bank S22 note is stale, files absent)
Decision: see [infra-change-flow-brainstorm.md](./infra-change-flow-brainstorm.md)

## Phase 1 - Free ideation

**Kira**
- Tenant already writes the annotation. They change `params.maxmemory`, kubectl apply, Redis resizes. If that is homework, we built the wrong SoT.
- Console slider is cute and I will not die on it. Undo is re-applying the old annotation, not a stack.

**Nova**
- Kira already took gitops-just-works. The actual bug is three freeze-points: `ensure_claim` 409 does not patch spec (main.py:205-208), `provision_infra` returns if Ready and the Secret has data (main.py:299-306), runner `POST /v1/runs` returns the in-memory success cache without looking at params (jit-runner/main.py:211-213). Unstick those.
- TTL-only changes must not call the runner. `softDeleteTTL` is claim math, not tofu.

**Sage**
- Do not apply because a Deployment update fired. Opt-in mutate: a generation or `jit.infra/redis.mutate: "once"` so a kustomize shuffle cannot replace a container.
- Record `status.lastAppliedParams`. Comparing against claim.spec is circular once we start patching spec. Closed CRD status list means a new field or the API server prunes it — infraclaim.yaml, not a wish.
- `postgres_password` is controller-owned (postgres/main.tf:45-52). It is not a tenant setting. Ever.

**Ivy**
- Two Deployments, one claim, first-writer-wins. Vote changes maxmemory, worker still has `params:{}`. Who applied, who was ignored, and which test fails when we get it wrong? Write that test before the code.
- Failed update must not enter Deleting. Initial Failed is terminal until the Deployment changes (main.py:849-853). An update failure is different: the old container is still serving.
- Change params twice while the first apply is in flight. `claim_lock` wraps `provision_infra`, not `ensure_claim` (main.py:150-152). Spec can move under an apply.

**Ops**
- `tofu apply`, not destroy-then-create. `docker_volume.postgres_data` is a managed resource (postgres/main.tf:21-25). `tofu destroy` deletes it. Recreate is data loss dressed as honesty.
- Redis `command` includes `--maxmemory` (redis/main.tf:30). A maxmemory change is a container replace at the provider. Say that in the demo. Do not sell "in-place".
- Rollback is re-annotate. No new verb. If apply is going to sit in a kopf handler for up to 600s (call_runner timeout, main.py:488; tofu timeout, jit-runner/main.py:137), I want a condition I can see, not a silent hang.

**Remy**
- Premise: this requirement is wrong. JIT infra is throwaway. Changing maxmemory on a 10-minute Redis is petting cattle. Delete the Deployment, wait the TTL, come back. We already sold two-speed cleanup as the product.
- If the premise loses, the build is a drift condition, not an apply path. Tell them the annotation lied. Do not teach tofu to chase kubectl.
- Cut `moduleVersion` (runner-api.md: currently unused), cut `postgres_db` (init-only on a live volume), cut passwords. v1 is one param or it is not a PoC.

## Phase 2 - Debate

**Remy -> everyone:** You are designing a mutate API for a database the tenant was told not to get attached to. Why is "change a setting" a requirement rather than "replace the claim"?

**Kira:** Because ADR 0001 already said the annotation is the only thing a human writes and the claim is derived state. Today that is a lie after the first apply. They will edit `jit.infra/redis`. Gitops will apply it. Redis will still be 256mb (variables.tf default) and the annotation will say 128mb. Silent drift is worse than not having a feature. We are not adding a verb. We are making the SoT true.

**Nova:** Remy, replace-the-claim is `tofu destroy`. Ops already pointed at the volume. Soft-delete waits 10m (vote-deployment.yaml TTL) and still destroys the volume when it finally sweeps. That is not "change maxmemory".

**Remy:** Fine. The requirement as a new API is wrong; the requirement as "stop lying about the annotation" I will live with. Do not add a phase to the state machine for it.

*synthesised into: not a mutate API, repair ADR 0001 after first apply. Premise challenge loses on the SoT-lie argument.*
*conceded by Remy on the requirement; not conceded on scope (no new phase, cut moduleVersion/postgres_db/passwords).*

**Sage -> Kira:** A rollout that rewrites the annotation JSON still fires `handle_deployment`. You will tofu-replace Redis because someone sorted keys.

**Kira:** parse_annotations only reads `jit.infra/*`. If params equal last-applied, skip. That is a compare, not a two-phase commit. A mutate token is homework. Tenants will forget it and open a bug that "annotate does nothing".

**Nova:** Sage, I checked. Today's Ready+Secret skip already no-ops rollouts that do not change jit.infra params. Converge with skip-if-equal keeps that. Generation-gated is Converge plus a protocol nobody asked for.

**Sage:** Rollouts, conceded — skip-if-equal covers them. Destructive params do not. `POSTGRES_DB` is an init-time env (postgres/main.tf:59). Changing it replaces the container, the volume keeps the old data dir, the new env is ignored. Silent no-op. That needs a gate or a refuse.

**Ops:** Then refuse in v1, do not invent a mutate annotation. Allowlist or "undefined, do not demo it". I will not page because postgres_db drifted.

*Sage conceded the rollout/generation argument. Unresolved -> open question: mutable-param allowlist vs tofu-decides vs UpdateBlocked on non-demo params. Owner: Sage, Ops.*

**Ops -> Nova:** I still want to see Updating. A 600s handler with no phase looks like a dead controller.

**Nova:** 600s is the timeout cap, not the expected duration. Assumed: redis container replace is seconds. A new phase touches jit-infra-flows.md section 4, which the design note itself says is the novel logic and must stay current. Conditions already exist. `Updating=True` and `UpdateFailed=True` are jsonpathable. Failed-as-phase is for initial provision (main.py:359-366). Do not reuse it.

**Ivy:** I need something falsifiable. "Condition Updating True then False within one 30s resync tick plus one apply" I can write. A phase I can also write. Either works. What I cannot write is "the controller intended to skip".

**Remy:** No phase. State machine growth is how this PoC stops being a PoC. Condition only.

**Ops:** Condition only, if it is set before the runner call and cleared on success. If you skip the condition because the apply was fast, I cannot tell a hang from a no-op.

*synthesised into: no new phase; conditions Updating / UpdateFailed. Ops conceded the phase, not the observability.*

**Ivy -> Nova:** First writer wins (jit-infra-poc.md:188-191, main.py:646-675). Vote updates maxmemory, worker still has `{}`. If Converge "syncs from the annotation that changed", you flip-flop every event. If it syncs from claim.spec, the update is ignored and Kira's SoT is still a lie for the editor.

**Kira:** The winner changing their mind is not a conflict. The loser changing theirs is. If every remaining reference agrees on the new params, that is also a win — the original writer may be gone.

**Nova:** So: winner's annotation is the desired update. Losers still get ParamsConflict. Unanimous remaining refs can move the claim. That is first-writer-wins with "writer changed their mind", not last-writer-wins.

**Ivy:** Put it in a checkpoint or I will vote against Converge. Two Deployments in the fixture, patch the loser, assert no tofu, patch the winner, assert container command.

*synthesised into: first-writer-wins survives; winner-changed-mind and unanimous-refs apply. Ivy's dual-writer case becomes an acceptance criterion, not a veto yet.*

**Ivy -> Nova:** Spec moves under apply. handle_deployment patches via ensure_claim without the lock, then waits on claim_lock for provision_infra.

**Nova:** Re-read spec under the lock before POST. After apply, re-read once. If it drifted, leave Updating set and let the 30s resync take it. Do not loop in the handler. 600s once is enough.

**Sage:** lastAppliedParams must be what you actually sent, not what spec is now. Otherwise the skip-if-equal lies.

*synthesised into: re-read spec under claim_lock; one apply per handler; resync is the backstop; lastAppliedParams is the skip key. CRD edit required.*


**Ops -> Remy:** Recreate is not the conservative option. tofu destroy deletes `docker_volume.postgres_data`. Converge is tofu apply: volume resource unchanged, container may replace. Redis has no volume. Demo on redis.

**Remy:** Then do not pretend Converge is in-place. Ops already said maxmemory is ForceNew on command.

**Ops:** I said say it in the demo. I did not say destroy the volume to look honest.

*Recreate killed as the default path because tofu destroy deletes the postgres volume. Survives as a losing concept for "explicit blast radius".*

**Kira:** Console slider — killed. Console is a read model (0004). Do not give it a write path in the same step as the control plane.

**Remy:** moduleVersion — cut. Runner ignores `version` (runner-api.md). Shipping a version bump that no-ops is another SoT lie.

**Sage:** Agreed, deferred.

*Console slider killed. Undo stack killed (re-annotate is rollback). moduleVersion deferred. postgres_password never tenant-updated.*

**Ivy:** What happens on runner cache after we fix the controller only?

**Nova:** Nothing. Controller POSTs new params, runner returns old outputs, Secret rewritten with the same data, we stamp lastAppliedParams, and now skip-if-equal thinks 128mb is applied. The bug becomes untestable. Runner must compare params before returning the success cache.

*Runner change is required for every apply-based concept, not optional.*

**Remy -> Kira:** Drift-only. Set AnnotationDrift, do not apply. Cheap. Testable. Does not teach the controller to replace containers from a JSON blob.

**Kira:** Then the tenant still has to destroy to converge. You walked back the premise and kept the conclusion. If we can see the drift we can apply it.

**Ivy:** Drift-only is the most testable thing in this room. I could live with it for v1 if Converge's dual-writer checkpoint is hand-waved.

**Remy:** I am voting it.

*not killed — promoted to Concept 2. Remy + possibly Ivy.*

## Phase 3 - Final pitches

Coupling unit: the Deployment annotation is desired state; InfraClaim.spec is a projection; terraform state in MinIO is actual. Alternative unit — InfraClaim.spec as the write surface — loses because tenants do not author the CR (ADR 0001; they cannot edit the Namespace either). Alternative unit — "the claim is immutable, replacement is the change" — is Concept 2.

### Concept 1 - Converge
Annotation stays SoT. On Deployment update, patch InfraClaim.spec from the param winner (first writer who changes their mind, or unanimous remaining refs). If spec.params != status.lastAppliedParams, set condition Updating, POST /v1/runs with the new params (runner applies when params differ; success-cache only when they match). On success, write lastAppliedParams, rewrite Secret, clear Updating. TTL-only: patch spec, no POST. Failure: phase stays Ready, UpdateFailed=True, never Deleting. Rollback = re-annotate previous params. v1 demo: redis maxmemory. moduleVersion ignored. postgres_password not in the tenant update set.
- Touches: jit-controller/main.py, jit-runner/main.py, deploy/crd/infraclaim.yaml, docs/designs/jit-infra-flows.md (note on Ready+conditions, no new phase)

### Concept 2 - Drift-only (immutable claims)
Claims are immutable after first Ready. If the winner's annotation params != lastApplied (or != spec), set AnnotationDrift. Do not POST. Tenant destroys (soft TTL or namespace) to take the new params. First-writer-wins unchanged.
- Touches: jit-controller/main.py, deploy/crd/infraclaim.yaml (only if lastApplied is a new field; could compare spec which already froze at create)

### Concept 3 - Recreate
Param change is DELETE /v1/runs then POST. Honest container death. IP kept on the claim so EndpointSlice stays. postgres volume dies with tofu destroy.
- Touches: jit-controller/main.py, jit-runner/main.py (cache drop on destroy already happens)

### Concept 4 - Generation-gated
Converge, but apply only when a mutate generation annotation increments. Skip-if-equal is not enough for Sage's destructive-params case.
- Touches: everything in Concept 1 plus annotation schema, docs, demo manifests

## Vote
| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | Annotation is already the write path. Drift-only leaves the SoT lying. |
| Nova | 1 | Three freeze-points. Smallest code that makes ADR 0001 true. No phase. |
| Sage | 4 | Still thinks destructive params need a gate. Skip-if-equal does not refuse postgres_db. |
| Ivy | 2 | Dual-writer update is the untestable bit. Would move to 1 if the checkpoint names winner-vs-loser. |
| Ops | 1 | Recreate destroys docker_volume. Converge via tofu apply is the smaller blast radius, as long as the demo says Redis is replaced. |
| Remy | 2 | Premise still stands for apply. Drift-only ships, does not pet the cattle. Tie-break unused. |

