# Tenant Settings Change - Brainstorm Transcript
Date: 2026-09-25
Team: Kira, Nova, Sage, Ops (SRE swap-in for Milo), Ivy, Remy
Premise challenge: Remy
Context read: jit-controller/main.py (parse_annotations, handle_deployment, ensure_claim, provision_infra, check_param_conflict, resync_referenced_by, destroy_infra), deploy/crd/infraclaim.yaml, jit-modules/modules/{redis,postgres,pgadmin}/variables.tf, jit-modules/modules/{redis,postgres}/main.tf, docs/designs/annotation-to-state.md, docs/designs/jit-infra-flows.md, docs/designs/runner-api.md, memory-bank/{systemPatterns,projectbrief,activeContext,progress}.md
Decision: see [settings-change-brainstorm.md](./settings-change-brainstorm.md)

## Facts established before ideation

1. Today a param change is a silent no-op. `handle_deployment` fires on update, but
   `ensure_claim` swallows the 409 without patching spec (first-writer params stay),
   and `provision_infra` early-returns when phase=Ready + Secret has data. A
   single-writer change does not even trip `check_param_conflict` (`len(refs) < 2`).
2. Settled: authoring surface = Deployment annotations; ownership via ownerReference
   to the Namespace (memory-bank/systemPatterns.md). First-writer-wins across
   Deployments, surfaced via `ParamsConflict` condition - already shipped.
3. Per-param apply reality (docker provider): redis `maxmemory` is container
   `command` - recreate, no volume, takes effect, loses cache contents. postgres
   `postgres_db` is env - recreate, but the named volume persists and initdb runs
   only on empty dirs, so the change silently does nothing. `name`/`ip`/`network`
   are controller-owned identity (an IP move breaks the EndpointSlice).
   `postgres_password` is controller-owned, reused from the Secret by design.
4. Runner `POST /v1/runs` is an idempotent `tofu apply`; per-(workspace,module)
   lock; the runner is deliberately dumb.
5. The CRD status schema is enumerated - a new status field (e.g.
   `lastAppliedParams`) gets pruned unless the CRD is redeployed. `spec.params`
   already has `x-kubernetes-preserve-unknown-fields`.
6. Failed phase is terminal until a Deployment event re-fires (main.py:851).
7. The app consumes env-from-Secret at pod start - a Secret rewrite does not reach
   running pods without a rollout.
8. Out of scope (projectbrief.md): snapshot-before-destroy, `retain: true`, async
   provisioning, real IAM.
9. Sourced numbers: resync 30s (main.py:815), softDeleteTTL default `30d`
   (main.py:148), redis `maxmemory` default `256mb` (redis/variables.tf:18),
   postgres_db default `voting` (postgres/variables.tf:24), pgadmin http_port
   `5050` (pgadmin/variables.tf:19), IPAM 10 IPs/namespace
   (docs/designs/annotation-to-state.md).

## Phase 1 - Free ideation

**Kira**
- Edit the same annotation, controller notices, applies it, and tells you what
  happened. Same surface as create - nothing new to learn.
- The outcome must be visible where the tenant looks: their Deployment and
  `kubectl get infraclaim`. A condition that says "applied" or "rejected, and why"
  in plain language.
- Console button for tuning maxmemory later. Not now.

**Nova**
- Diff annotation params vs claim `spec.params` inside the existing flow; on
  change: patch spec, re-run `provision_infra` minus the Ready early-return,
  rewrite the Secret. The runner apply is already idempotent - this is wiring,
  not a new engine.
- Per-module param classification: mutable / unsafe / identity. Identity keys
  (`name`/`ip`/`network`) are already force-overridden today; an update attempt
  on them gets rejected with a message.
- Emit a k8s Event on the Deployment (`ParamsApplied`/`ParamsRejected`) - tenants
  watch their Deployment, not our CRD.

**Sage**
- Record what the runner actually applied, not just what was asked. Three states
  exist (annotation = desired, spec = recorded, runner = actual); at minimum the
  controller must know desired vs applied, or a failed apply is invisible.
- Reject tenant attempts to set controller-owned keys (`postgres_password`,
  identity triple) explicitly. Today they are silently overridden, which is
  tolerable on create and confusing on update.
- `postgres_db` on a live volume is a lie - initdb runs once. Either classify it
  unsafe and reject, or implement `CREATE DATABASE` properly. Do not "apply" it
  and report success.

**Ops**
- Blast radius classes: redis `maxmemory` recreate = cache flush, acceptable.
  pgadmin env/port recreate = stateless, acceptable. postgres `postgres_db` =
  data-preserving lie, reject. Anything that would drop the postgres volume = out
  of bounds without snapshot, which is out of scope.
- Rollback: if an update apply fails midway, the claim must keep the *last
  applied* params somewhere destroy can reach - destroy already builds vars from
  `spec.params`; do not let a broken desired value pollute that.
- Serialize updates with the existing `claim_lock`; an update must never
  interleave with the TTL sweep's destroy.

**Ivy**
- Edge cases I want named, not discovered: change while Orphaned (resurrection
  path does not reprovision today), change while Pending, change while Failed,
  change that fails inside tofu, two writers changing to the *same* new value,
  Secret rewritten while pods keep stale env.
- The stale-env one is a product lie: "your setting changed" while the app still
  holds the old value in its environment.
- Whatever ships gets an end-to-end checkpoint script in the S-series style:
  annotate a change, assert container + condition, PASS/FAIL. Not a follow-up
  ticket.

**Remy**
- Premise challenge: the tenant should not change settings on JIT infra at all.
  This is ephemeral, TTL'd, cattle infrastructure - its entire selling point is
  disposability. A tenant who wants a different `maxmemory` deletes the annotation
  and re-adds it. Building a day-2 update plane for disposable infra solves a
  problem this PoC does not have. The requirement should be: *document the
  delete-and-redeclare flow.*
- Whatever survives that challenge: v1 is small. No new CRD version if avoidable,
  no console, no approval workflows.

## Phase 2 - Debate

**Kira -> Remy:** Your workaround does not work. Delete the annotation and re-add
it inside the soft-delete window and the claim *resurrects* - `Orphaned -> Ready`,
"same container, data intact, nothing reprovisioned" (jit-infra-flows.md). The
tenant gets their old settings back and a green Deployment. The naive path returns
the old state silently.

**Sage -> Remy:** Seconded, and worse: re-add races the TTL sweep. The claim is
Namespace-owned with a finalizer; whether the re-added annotation lands before or
after the 30s sweep tick decides whether you keep data or lose the volume. A
workaround whose outcome depends on a timer is the worst kind.

**Remy:** Then the honest version of my position is: wait for the TTL, let it
destroy, redeclare. Data loss, minutes of downtime, but zero new machinery.

**Ops -> Remy:** That is the correct answer for exactly one class - changes that
*must* recreate with data loss. For "raise redis maxmemory", destroy-and-wait is
absurd: the change is a container restart. Your premise challenge survives as
scope, not as veto.

**Remy:** Accepted. Concede the veto; the challenge converts to a scope cut: v1
handles changes that apply safely in place. Recreate-with-data-loss stays "delete
and redeclare", documented.
*— conceded, converted to the v1 class split.*

**Nova -> Sage:** On "record what the runner applied": do we need
`status.lastAppliedParams`? That is a CRD change - the status schema is
enumerated, unknown status fields get pruned (infraclaim.yaml). Alternative:
**`spec.params` becomes last-applied**. The controller patches spec only *after* a
successful apply. Annotation vs spec is then the pending diff, visible to anyone
with `kubectl`, and no CRD change.

**Sage -> Nova:** That collapses desired and applied into one field, and I want
them separate on principle - but your version has a property mine does not:
`destroy_infra` already builds its vars from `spec.params`. If spec is always
last-applied, destroy can never be poisoned by a failed desired value. That
answers Ops's rollback point by construction. Conceded, with one condition: the
diff must be recomputed on resync too, not only on Deployment events, or a spec
patch that fails to reach the API server is lost forever.

**Nova:** Agreed - resync compares annotation vs spec the same way the handler
does. And the Failed rule survives: a failed *update* sets a `ParamsUpdate=False`
condition and does **not** retry every tick (runner calls cost real seconds); the
next Deployment event retries. Same semantics as create, which is already the rule
at main.py:851.
*— synthesised: spec-as-applied, diff in handler + resync, no CRD change, failed
updates terminal-until-next-event.*

**Ops -> Kira:** Now the unsafe class. `postgres_db`: reject, or apply-and-lie?

**Kira -> Ops:** Rejecting feels like homework. But apply-and-lie is worse - the
tenant files a bug against us, not against their own understanding. Reject, with
the condition message saying *why* ("postgres_db cannot change on an existing
volume; delete and re-add the annotation to recreate").

**Sage:** And that message *is* Remy's delete-and-redeclare path, preserved as
documentation for exactly the class where he is right. The classification for v1,
from the facts: **mutable-in-place** = redis `maxmemory` (recreate, no volume,
cache flush), pgadmin `http_port`/`pgadmin_email`/`pgadmin_password` (recreate,
stateless, fresh sqlite applies them), `softDeleteTTL` (metadata-only, no runner
call - today it is *also* silently ignored, this fixes that for free).
**Rejected** = `postgres_db` (volume lie), `postgres_password` (controller-owned),
`name`/`ip`/`network` (identity). The map lives in the controller, ~20 lines,
hardcoded for three modules.

**Nova -> Sage:** Hardcoded map vs a `jit.yaml` manifest shipped in each module
directory?

**Sage:** The module author is the right owner of that knowledge - but a manifest
format is a runner+controller+modules change across three repos' worth of
surface. Hardcode it with a TODO. If a fourth module appears, revisit.

**Remy:** Hardcoded. Moving on.
*— synthesised: controller-side map, v1.*

**Ivy -> Nova:** My edge cases. Orphaned + change?

**Nova:** Cannot arrive while Orphaned - orphan means no referencing Deployment,
and changes arrive *on* Deployments. A re-added Deployment with new params hits
the resurrection path, which today does not reprovision. Under the diff design,
resurrection sees annotation != spec and the update fires. One code path covers
it.

**Ivy -> Nova:** Change while Pending or Failed?

**Nova:** `claim_lock` serializes; an update during Pending is just the next
provision attempt carrying newer params. Failed is precisely the "terminal until
Deployment event" case, and a param change *is* a Deployment event - retry path
already exists.

**Ivy -> Kira:** The stale-env lie. `maxmemory` does not touch the Secret, fine.
But if any update ever changes a Secret value - pgadmin outputs get rewritten -
running pods keep the old env. Do we tell the tenant it changed when their app
cannot see it?

**Kira:** Then the controller should restart the pods. Patch a hash annotation on
the referencing Deployments' pod templates; k8s does the rest.

**Ops -> Kira:** Absolutely not. A controller that mutates tenant pod templates is
a controller that can mass-restart a namespace on a bug. Surprise rollouts are
worse than stale env.

**Nova:** Compromise for v1: the update condition says `SecretUpdated` when
values changed, message says "restart pods to consume". The tenant runs
`kubectl rollout restart`. It is their pods, their timing.

**Kira:** Homework, but honest homework. I will take it - logged as my dissent.
*— unresolved -> open question: automatic rollout on Secret change (Kira, Nova).*

**Ivy:** And my checkpoint: new script, S19-shaped - annotate a `maxmemory`
change, assert the container's command changed, assert the condition cleared,
assert a rejected `postgres_db` change leaves the claim Ready with the rejection
condition. Part of the work, not a follow-up.

**Remy:** Accepted into scope. It is the only part of this that proves the rest.

**Sage:** One more from Phase 1 nobody picked up: I asked for explicit rejection
of controller-owned keys. Covered - it is in the rejected class. And my Phase 1
three-way state worry is dead with spec-as-applied. Threads closed from my side.

## Phase 3 - Final pitches

**Coupling unit:** the update is owned by the **InfraClaim** - the
`{namespace}-{module}` provisioning unit. The Deployment annotation is the
authoring surface, not the owner. Alternative: per-Deployment ownership (each
Deployment drives its own apply) - loses because claims are shared (vote+worker
share redis) and first-writer-wins already settled the sharing semantics. Second
alternative: the runner owns update semantics (controller forwards desired params
every resync; runner diffs via `tofu plan` and no-ops) - loses because the runner
is deliberately stateless and an apply-every-30s per claim costs real seconds; it
also collides with the Failed-terminal rule.

### 1. Desired-state diff with classified params
Annotation params are diffed against `spec.params` (= last successfully applied)
in both `handle_deployment` and the resync. On change: classify each key against a
controller-side map - mutable-in-place keys patch spec, call the runner's existing
idempotent apply, rewrite the Secret, set `ParamsUpdate=True`; unsafe keys
(`postgres_db`) and identity/controller-owned keys are rejected with
`ParamsUpdate=False` and a message naming the delete-and-redeclare path;
`softDeleteTTL` updates with no runner call. Failed updates are terminal until the
next Deployment event. Ships with an S-series checkpoint.
- **Pros:** no CRD change; destroy safety falls out of spec-as-applied; tenant
  stays on the annotation surface they already know; unsafe changes fail loudly
  with instructions instead of lying.
- **Cons:** trusts the docker provider's recreate decisions with no plan preview;
  the classification map is controller-hardcoded knowledge that belongs to module
  authors; stale-env consumption still needs a tenant-side pod restart.
- **Effort:** M (~3-5 days, assumed).
- **Touches:** `jit-controller/main.py` (diff in `handle_deployment` +
  `resync_referenced_by`, classification map, `provision_infra` update path,
  conditions), `docs/designs/annotation-to-state.md`,
  `app/docs/MANUAL-TESTING-GUIDE.md`, new `scripts/checks/S19.sh` (assumed
  numbering), `docs/designs/jit-infra-flows.md` (new update sequence diagram).

### 2. Claim-spec as the tenant-editable object
Tenants `kubectl patch infraclaim` directly; an `on.update(infraclaims)` handler
drives apply; the annotation handler mirrors annotation->spec for GitOps users.
Most k8s-native: the claim becomes a real desired-state object.
- **Pros:** enables kubectl-only operations; claim spec stops being a write-once
  artifact; matches how every other k8s controller works.
- **Cons:** two writers of spec (tenant + annotation mirror) need a conflict
  policy; contradicts the settled "authoring on the Deployment" decision; bigger
  API surface to document and test.
- **Effort:** M-L (~5-8 days, assumed).
- **Touches:** `jit-controller/main.py` (new handler, mirror logic),
  `deploy/crd/infraclaim.yaml` (likely), all three design docs.

### 3. Replace-only cattle
Any param change triggers a controller-orchestrated destroy+recreate (no tenant
two-step), gated by an explicit `confirmDestroy: "true"` annotation for stateful
modules. Semantics are honest by construction.
- **Pros:** one code path for all params, no classification; no docker-recreate
  trust needed; data loss is explicit, never silent.
- **Cons:** postgres loses its volume on every tune (snapshot is out of scope);
  minutes of downtime for a maxmemory bump; recreates IPAM and timing races the
  design worked to eliminate.
- **Effort:** M (~3-4 days, assumed).
- **Touches:** `jit-controller/main.py` (orchestrated destroy->provision),
  checkpoint scripts, docs.

### 4. Runbook-only
No code. Document the delete-and-redeclare flow as the supported way to change
settings.
- **Pros:** cheapest possible; zero new failure modes.
- **Cons:** the runbook is a trap today - re-add inside the TTL window resurrects
  the *old* params silently; the honest version requires waiting out the TTL with
  data loss; every tenant rediscovers this.
- **Effort:** S (~0.5 day, assumed).
- **Touches:** `app/docs/MANUAL-TESTING-GUIDE.md` only.

## Vote

| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | Same surface the tenant already knows; dissent: still wants automatic rollout on Secret change. |
| Nova | 1 | It is wiring, not an engine - diff + existing idempotent apply + conditions that already exist. |
| Sage | 1 | Spec-as-applied gives destroy-safety by construction; concept 2 is where this ends up long-term, not v1. |
| Ops | 1 | Unsafe class rejected by default with instructions; blast radius is honest. |
| Ivy | 2 | Concept 1 is testable, but it trusts the docker provider's recreate decisions with no plan gate; an explicit claim edit (2) is more falsifiable. Recording my dissent. |
| Remy | 1 | Premise challenge converted into the v1 class split; scope is contained. |

5-1 for Concept 1. The strongest argument nobody made against Concept 1: the
runner never shows a `tofu plan`, so the controller applies recreate-class
changes blind. Logged as an open question rather than reopening - the checkpoint
suite is the v1 mitigation.
