# Tenant infra settings-change flow - Brainstorm Transcript
Date: 2026-09-27
Team: Kira, Nova, Sage, Ivy, Remy, Ops (Milo swap for infra/platform)
Premise challenge: Remy
Context read: jit-controller/main.py, jit-runner/main.py, deploy/crd/infraclaim.yaml, jit-modules/modules/redis/main.tf, jit-modules/modules/redis/variables.tf, jit-modules/modules/postgres/main.tf, jit-modules/modules/postgres/variables.tf, jit-modules/modules/pgadmin/variables.tf, docs/designs/annotation-to-state.md, docs/designs/runner-api.md, docs/designs/jit-infra-flows.md. Excluded per the user's instruction: the prior spark-infra-change-flow-* notes in docs/design/ (a fresh run was requested; no prior decision constrained this debate). Not read: jit-modules/modules/pgadmin/main.tf - any pgadmin volume claim below is marked assumed.
Decision: see [infra-settings-update-brainstorm.md](./infra-settings-update-brainstorm.md)

## Roster brief (ground facts)

- Today a settings change does nothing: `provision_infra` sees phase Ready plus a populated Secret and early-returns (sourced: `jit-controller/main.py:299-306`). The annotation is parsed, the claim exists, the drift is never acted on.
- The runner is create-or-update - `tofu init` (MinIO backend, key `ns/{workspace}/{module}/terraform.tfstate`) then `tofu apply -auto-approve` with `-var` flags (sourced: `jit-runner/main.py:217-277`). A re-POST with new params would converge state. BUT `create_run` early-returns the cached outputs of any success entry, regardless of the params sent (sourced: `jit-runner/main.py:209-214`).
- `redis/main.tf:30` sets `command = ["redis-server", "--maxmemory", var.maxmemory, ...]`. `command` is a ForceNew attribute for the kreuzwerker/docker provider, so a maxmemory change REPLACES the container. Same name, same `var.ip`, no volume (the module declares none) - a connection blip, not data loss.
- `postgres/main.tf` declares a named volume with `remove_volumes = false`, so data survives container replacement. But POSTGRES_PASSWORD/POSTGRES_DB are container env, and the postgres image only runs initdb when the data dir is empty (sourced: postgres image entrypoint docs) - an env change against an existing volume replaces the container and then changes nothing.
- CRD status is a closed field list (phase, referencedBy, expiresAt, outputsSecret, endpoint, message, allocatedIP, conditions - sourced: `deploy/crd/infraclaim.yaml:34-68`). Unknown fields are pruned. `phase` has no enum: a new phase VALUE is free, a new status FIELD is not.
- `check_param_conflict` already implements first-writer-wins over differing annotation params, naming winner and ignored writers (sourced: `jit-controller/main.py:646-675`).
- Failed is terminal until the Deployment changes - the resync deliberately does not retry it (sourced: `jit-controller/main.py:851-853`). `call_runner` blocks up to 600s (sourced: `main.py:488`). Resync timer ticks every 30s (sourced: `main.py:815`).
- App pods read the Secret into env vars at container start; a Secret patch does not reach running pods.
- Deleting is only ever reached from Orphaned (TTL expiry) or the claim-delete handler.

## Phase 1 - Free ideation

**Kira**
- Edit the annotation, everything just converges. The tenant surface stays exactly one YAML field away from what they already know.
- A settings panel in the console that writes the annotation for you - nobody should hand-edit JSON inside a string.
- Update "receipts": after a change, the console says what changed and whether the app pods need a restart.

**Nova**
- Reuse the create path: on Deployment update events plus the 30s resync, diff annotation params against the claim's spec; on drift, re-POST /v1/runs. One loop, no new runner endpoint.
- Stamp last-applied params into status so the resync diff is a cheap string compare instead of a re-apply every tick.
- Smallest possible v1: detect drift, set a condition saying "parameter changes are not applied", ship nothing else.

**Sage**
- Flip ownership: the InfraClaim spec is the tuning API - operators edit it directly, RBAC-gated. The annotation is bootstrap-only.
- A per-module safe-param allowlist derived from the modules' variables.tf, so tuning rights are explicit rather than emergent.
- A data-loss gate: refuse any update whose apply would replace a resource that owns a volume.

**Ops**
- In-place converge keeping the IP and container name; write Secret/Service/EndpointSlice only after the runner succeeds; a failed update leaves live objects untouched.
- Advisory restart signal as a condition - the controller never rolls tenant pods.
- Every update path must survive a controller restart mid-apply: state lives in claim status, retries are idempotent.

**Ivy**
- Destroy + recreate IS the update. One code path already exists and is tested; the assertion is "the endpoint comes back on the same IP".
- Every give-up must be falsifiable within one resync tick - a stuck state with no condition is a bug, not a corner.
- Check the premise that in-place tuning even exists here: if maxmemory is in the container command, "in-place" is a lie the tests will expose.

**Remy**
- Premise, filed now for Phase 2: nobody tunes anything. Immutable infra, change = recreate, document it, ship nothing.
- If we must ship something: allow exactly the params that change nothing structural, and answer everything else with "delete your claim".
- Whatever we build must not add a runner endpoint.

## Phase 2 - Debate

**Remy -> all:** You are building an update machine for a demo whose checks all assert that things stay Ready. `scripts/checks/` freezes current behavior; the console read model assumes the phase machine in jit-infra-flows.md; the orphaning demo is the showpiece. Who asked for tuning? Tenants get redis, postgres and pgadmin with working defaults. The PoC philosophy is immutable infra - recreate to change. Why is the answer not "document that"?

**Kira:** Because the first "can I bump the memory?" question gets "delete your namespace", and that is homework, not delight. The claim already exposes params in the console read model - the UI invites editing, then silently ignores it. Silent no-ops are worse than no feature.

**Sage:** And the code half-promises it. `check_param_conflict` implements first-writer-wins over params that differ between writers (sourced: main.py:646-675). That function only makes sense in a world where params can want to change. Immutable infra would mean deleting it, not shipping around it.

**Ops:** Remy's blast-radius point is right about one thing: the update flow must not be able to do what destroy does by accident. That is an argument for a gate, not for no feature.

**Remy:** Concede in part - but I hold the scope knife: the v1 param surface is as small as the facts allow, and if the facts allow nothing, I win.

*Premise answered - proceed, scoped. Remy keeps the knife on the param allowlist.*

**Ivy -> Ops:** Before anyone says "in-place": `maxmemory` sits in the container command (sourced: redis/main.tf:30). Command is ForceNew for the docker provider, so the marquee "safe tune" REPLACES the container. There is no in-place redis tune in this codebase.

**Ops:** The replace keeps the name and `var.ip`, and redis has no volume - the module declares none. So the cost is a listening gap for the apply window, not data. EndpointSlice points at a dead address briefly and is right again after.

**Nova:** Which reframes the gate. "Safe" cannot mean "no replace" - nothing here is replace-free. It has to mean "replace is tolerable": stateless, or the volume survives.

**Ivy:** For redis, tolerable. For postgres, the env trap: POSTGRES_PASSWORD and POSTGRES_DB live in container env (sourced: postgres/main.tf:44-60), but the image only initializes a fresh data dir. Change the env against an existing volume, tofu replaces the container, postgres starts on the old data and IGNORES the new values. The Secret would then say the new password while the container holds the old one. That is not a no-op, that is divergence.

**Sage:** And the controller would happily write the new password into the Secret after the "successful" apply - `runner_params["postgres_password"]` flows straight into outputs (sourced: main.py:377-378). A tenant rotates a credential, gets a green Ready, and the old password still opens the database. Security incident shaped like a feature.

**Ops:** Conceded: postgres has no safely updatable param in v1. Rotation against a populated data dir needs `ALTER USER`, which tofu-docker cannot express. The allowlist is not "safe params" - it is "params whose replacement is tolerable".

**Remy:** Which is my "one knob" after all. Your own facts gave me the knife back.

**Nova:** Different reason though. Yours was scope; this is physics. Same list, better justification.

**Ivy -> Ops:** Now success. You said "patch the Secret after the runner succeeds". What does success assert for a maxmemory change? The outputs - address, port, url - are byte-identical before and after. The Secret bytes do not move. Your test passes on a run that did nothing.

**Ops:** Then success is not Secret bytes, it is the apply completing with the new params and the claim recording them. A status field - last-applied params - advances only on a verified apply, and the Secret is re-patched even when identical.

**Ivy:** And while the apply runs - up to 600 seconds (sourced: main.py:488) - the claim sits Ready while the container behind it is being replaced. The console would lie the whole window. You need a phase that says mid-update, or at minimum a condition.

**Ops:** Fair. New phase value - Updating - which needs no CRD edit since phase is a free string. The status FIELD for last-applied params does need a CRD edit; status is a closed list.

**Nova:** And on failure - resync treats Failed as terminal until the Deployment re-fires (sourced: main.py:851-853). If an update fails, the annotation already changed; nothing will re-fire. Who retries?

**Remy:** Nobody, deliberately. Retrying a failing 600s apply every 30s is a denial-of-service against the runner we run ourselves.

**Ops:** Failed update keeps serving the old Secret - the live objects are never touched - and the claim goes back to Ready with an UpdateFailed condition carrying the runner message. Retry happens when the tenant re-annotates. Same contract as create: Deployment change retries, resync does not.

**Ivy:** Falsifiable within one tick, then I am satisfied. If the condition does not appear in one 30s tick, the check fails.

**Nova -> Sage:** Your claim-as-API: who wins when a Deployment re-applies over an operator's spec edit? Annotation wins and the edit is silently stomped; spec wins and the annotation lies about desired state. Pick one.

**Sage:** Annotation wins - the resync's lease model depends on it. Which means my spec-as-API is a second writer that always loses. Conceded as the primary; the claim spec stays a synced copy of the annotation.

**Nova -> Ops:** One more coupling: pgadmin resolves its postgres_url and password from the jit-postgres Secret at provision time (sourced: main.py:257-278). Any future postgres change ripples into pgadmin's params.

**Sage:** Noted for the allowlist design: the gate is per-claim, but the dependency is cross-claim. v1 dodges it because postgres cannot change. The day it can, pgadmin needs a cascade.

**Ivy -> all:** Orphan interaction. Update in flight, refs go away mid-apply. Next tick the resync orphans the claim - but the apply is still holding the claim lock and the runner lock.

**Ops:** The resync's provision path takes `claim_lock` non-blockingly? No - it blocks. So the orphan transition waits for the apply to finish, then orphans a freshly-updated claim. Harmless: the container runs until TTL expiry, same as any orphan.

**Ivy:** Acceptable, but the check must assert it: refs gone during Updating ends in Orphaned within two ticks, never Deleting.

**Nova -> all:** Last mechanical one - the runner cache. Re-POSTing with new params returns the OLD cached outputs, full stop (sourced: jit-runner/main.py:209-214). Every converge concept on this board is a no-op until the cache compares params, not just presence.

**Ops:** Known, it is in the touches. Runner compares request params against the cached entry's params; mismatch re-applies. Small diff, but it is a hot-path behavior change.

*Remy, closing:* Then my verdict: ship the machine only as wide as `redis maxmemory`, refuse everything else with a named condition, and do not touch the runner's API surface beyond the cache fix. That I can defend to the timeline.

## Phase 3 - Final pitches

**Coupling unit, named:** the *claim* (not the Deployment, not the namespace) owns the update. The annotation is desired state, the claim is the recorded state machine, the runner apply is the effect. The Deployment is just one of possibly many writers. The alternative unit - the Deployment owning updates directly (apply per annotating Deployment) - loses because two Deployments share one claim, and per-writer applies would race the shared container name that `claim_lock` and the runner's `_run_lock` exist to protect.

### 1. Converge - annotation to spec sync to runner re-apply
On Deployment events plus the 30s resync, diff the winning annotation's params against a new `status.observedParams` (last-applied, added to the CRD). On drift: patch `spec.params` to match the annotation, set phase `Updating`, re-POST the full param set to `/v1/runs`. On success: re-write Secret/Service/EndpointSlice (even if byte-identical), advance `observedParams`, phase `Ready`. On failure: phase back to `Ready` with an `UpdateFailed` condition naming the runner error - old outputs keep serving, no auto-retry. A params allowlist (v1: `redis.maxmemory` only) refuses everything else with `UpdateRefused` naming the param. Secret content change sets an advisory `AppRestartRequired` condition; the controller never rolls tenant pods. Rollback is re-annotating the old value through the same path.
- **Pros:** single tenant surface (annotations only); IP and container name preserved by the tofu replace; rollback is free; `check_param_conflict` and the lease model keep working because the spec stays a synced copy.
- **Cons:** two hot-path behavior changes at once (controller Ready-skip must compare params, runner cache must compare params); a 600s synchronous apply inside a kopf handler; every allowed tune is actually a container replace with a listening gap; `observedParams` needs a CRD schema edit.
- **Effort:** M (~5-7 days - controller drift/phase/conditions, runner cache fix, CRD edit, checks script, jit-infra-flows.md state machine update; day range is a team estimate, not a measurement).
- **Touches:** `jit-controller/main.py` (`handle_deployment`, `provision_infra`, `resync_referenced_by`, `check_param_conflict`), `jit-runner/main.py` (`create_run` cache), `deploy/crd/infraclaim.yaml`, `docs/designs/jit-infra-flows.md`, `scripts/checks/S22.sh`.

### 2. Recreate-is-the-update
Drift triggers the existing `destroy_infra` + `cleanup_k8s_resources` + fresh `provision_infra` on the same IP. No phases, no cache fix, no CRD edit.
- **Pros:** one code path, and it is the tested one; no new runner semantics at all; trivially testable - the endpoint comes back on the same IP or the check fails.
- **Cons:** pays the full destroy window for every tune including refused ones; for postgres it is the divergence trap with extra steps (volume survives, env ignored, Secret rewritten wrong); the undeploy demo's S18 assertion sits in the same blast radius; no record of which params are applied.
- **Effort:** S (~2-3 days; estimate).
- **Touches:** `jit-controller/main.py` (resync drift detection wired to the destroy path).

### 3. Claim-as-API
Operators edit `InfraClaim.spec.params` directly, RBAC-gated; the annotation is bootstrap-only; the controller watches spec generation and re-applies.
- **Pros:** real API semantics - `kubectl diff` works on the thing being changed; RBAC is free Kubernetes; no JSON-in-a-string.
- **Cons:** two sources of truth during migration; every Deployment re-apply must not stomp the edit, which means freeze logic nobody asked for; tenants learn a second object; breaks the annotation-as-lease model the resync depends on.
- **Effort:** M (~3-5 days plus RBAC and console changes; estimate).
- **Touches:** `jit-controller/main.py`, `deploy/controller.yaml` (RBAC), console read model.

### 4. Plan-gated converge
Concept 1, but the safe/unsafe gate is not a static allowlist - the runner runs `tofu plan`, parses the plan JSON, and refuses any apply that replaces a resource owning a volume.
- **Pros:** the gate is grounded in tofu's actual behavior instead of a hand-maintained list; new modules inherit the gate automatically; catches the postgres divergence class mechanically.
- **Cons:** requires a plan endpoint or a plan-then-apply two-phase call in the runner (Remy's no-new-endpoint rule dies); plan JSON schema is a moving surface; Ivy's CI objection - asserting on a plan requires a live docker provider in tests; the 2x apply cost per update.
- **Effort:** L (~8-12 days; estimate).
- **Touches:** `jit-runner/main.py` (plan endpoint or two-phase), `jit-controller/main.py`, `deploy/crd/infraclaim.yaml`.

## Debate highlights
- **Remy's premise challenge (is tuning needed?):** immutable infra would ship nothing. *Answered:* the codebase already promises changeable params (`check_param_conflict`), the console invites edits it silently ignores - proceed, but the v1 allowlist is exactly one param.
- **Ivy vs Ops on what "in-place" means:** `maxmemory` is ForceNew container replace (sourced: redis/main.tf:30). *Synthesised:* "safe" means replacement is tolerable (stateless or volume survives), not that nothing is replaced.
- **Sage + Ivy vs Ops on postgres updates:** env changes against an existing volume are applied to the Secret and ignored by the container - password divergence. *Synthesised:* postgres has no updatable params in v1; rotation needs `ALTER USER`, out of scope for tofu-docker.
- **Ivy vs Ops on testable success:** byte-identical outputs make Secret-byte assertions vacuous. *Synthesised:* `status.observedParams` advancement is the assertion; `Updating` phase closes the lying-Ready window.
- **Nova vs Sage on two sources of truth:** spec-as-API always loses to the annotation on Deployment re-apply. *Conceded by Sage - candidate for Roads not taken.*

## Roads not taken
- **Claim spec as the desired-state owner** (raised by Sage, conceded in Phase 2): the strongest case was real API semantics - `kubectl diff`, RBAC, no JSON-in-a-string. It lost because the annotation is also the lease, and any re-apply of a tenant Deployment must either stomp the edit or let the annotation lie. It would win if tenants ever stopped writing annotations - an operator-only platform where the claim is provisioned once by tooling and tuned forever after.
- **Per-Deployment updates instead of per-claim** (rejected at the coupling-unit step): each annotating Deployment would converge the shared container. Lost immediately - two writers, one container name, exactly the race `claim_lock` and the runner's `_run_lock` were built to end.

## Vote
| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | The tenant surface never grows; the console stops lying about edits it ignores. |
| Nova | 1 | Reuses the create path end to end; the runner diff is five lines, not an API. |
| Sage | 1 | With `UpdateRefused` the divergence trap is closed by default, not by discipline. |
| Ops | 1 | Identity (IP, name, Secret) survives every update; failed updates touch nothing live. |
| Ivy | 2 | Concept 1's success signal is testable now, but the Updating window is still underobserved in a 600s blocking handler; 2 has exactly one moving part. |
| Remy | 2 | Smallest shippable answer to the premise; if the one-knob allowlist is the whole feature, destroy+recreate is the same feature with less machine. |

4-1-1 to Concept 1. Strongest argument against the winner, unmade in the debate: nobody priced what happens when TWO updates queue - a second annotation change during a 600s Updating window. Remy should have made it; the resync cannot start what it cannot see, and the params diff at the next tick would re-enter an in-flight update. Recorded as an open question rather than a reopened debate.
