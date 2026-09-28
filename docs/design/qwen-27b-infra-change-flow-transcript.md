# Infra Change Flow - Brainstorm Transcript

Date: 2026-09-26
Team: Kira (product), Nova (client/interaction), Sage (core/services), Ivy (QA), Remy (producer), Ops (SRE - infra swap for Milo)
Premise challenge: Remy
Context read: jit-controller/main.py (all 1007 lines), docs/designs/annotation-to-state.md, docs/designs/jit-infra-flows.md, docs/designs/runner-api.md, deploy/crd/infraclaim.yaml, jit-modules/modules/{redis,postgres,pgadmin}/variables.tf, docs/decisions/0001-0004, memory-bank/systemPatterns.md, docs/todo.md (S1-S21 all checked)
Decision: see [infra-change-flow-brainstorm.md](./infra-change-flow-brainstorm.md)

## Brief (Step 0 facts)

- Today a settings change on a Ready claim is a silent no-op: `ensure_claim` is create-only (409 logged and dropped, main.py L181-208), `provision_infra` skips Ready claims with a data-carrying Secret (L299-306), and the 30s resync (L815) recomputes only `referencedBy`, orphan/TTL and `ParamsConflict`.
- The runner's `POST /v1/runs` is already create-or-update: copy module → `tofu init` (MinIO backend, key `ns/{ws}/{module}/terraform.tfstate`) → `tofu apply -auto-approve` → outputs (runner-api.md). Runs are serialised per `(workspace, module)` (asyncio lock); the controller's HTTP timeout is 600s (main.py L488). The runner's in-memory registry is lost on restart; the controller's resync is the recovery path.
- Tenant-facing params today: redis `maxmemory`; postgres `postgres_db`, `postgres_password` (controller-generated, persisted in the `jit-postgres` Secret, reused across re-provisioning because the data dir carries its own password); `softDeleteTTL` (controller-local, read from claim spec in resync); `moduleVersion` (sent to the runner, ignored - modules are local files, runner-api.md L62).
- The `jit-{module}` Secret is create-then-patch on 409 (L444-449); the headless Service is patched on 409 (L509-519); the EndpointSlice is create-only (L548-551). App env vars resolve at container start (platform behaviour) - a Secret change is not an app change until a restart.
- Params: first-writer-wins with a `ParamsConflict` condition (L646-675); the winning writer is not recorded anywhere.
- Container removal takes its volume (systemPatterns.md; S17 J6) - a postgres replace is data loss.
- CRD `status.phase` is a free string (deploy/crd/infraclaim.yaml L37-38); `status.conditions` exists (L53-59); the status schema is a closed property list - a new status field must be added to the CRD or the API server prunes it.
- ADR 0001: authoring on the Deployment (tenant-writable), ownership on the Namespace.
- Cadence: S1-S21 all checked (docs/todo.md); `scripts/checks/` is frozen; new work is S22+.

## Phase 1 - Free ideation

**Kira**
- Annotate-and-done: `kubectl annotate` the Deployment, watch `make state` flip within a minute, timeline (S21) records it. No new surface.
- A console settings panel that writes the annotation for the tenant.
- A change must be reversible by re-annotating - the manifest is the undo button.

**Nova**
- Reuse the create path: on the update event, if the claim is Ready and params differ, patch spec, flip the phase, let existing `provision_infra` re-drive the runner - tofu apply converges.
- Resync backstop: 30s tick compares normalized annotation params vs `spec.params`, converges drift.
- Event-driven first (the handler already fires on update); resync is the safety net, not the main loop.

**Sage**
- A distinct `Updating` phase with the target params in a condition - in-flight changes are observable, and a second change coalesces instead of queueing.
- Record `status.paramSource` - the Deployment whose annotation the spec was synced from. "Who is authoritative" becomes a fact, not folklore.
- Classify params in-place vs replace-forcing, and warn before a re-apply that wipes postgres data.

**Ivy**
- The bug we ship is the silent no-op: a drift detector that quietly gives up (two writers disagree, event missed, runner restart) leaves the tenant believing the change applied. Every give-up must be visible.
- A deterministic rule for which annotation wins when two Deployments name the same module with different params - first-writer-wins has no recorded writer, so drift detection has no anchor.
- The test is a round trip: change a param, assert convergence; change it back, assert convergence again.

**Remy**
- Ship the smallest convergence: event path + spec sync + re-apply. No new runner endpoint, no CRD change beyond status.
- Cut the param classification - tofu already decides in-place vs replace; document the consequence.
- (Premise challenge, Phase 2.)

**Ops**
- A change must not strand the namespace: a failed update leaves a recoverable Ready-or-Failed claim, never a zombie that blocks teardown. The Deleting machinery is S17-proven - don't route through it.
- Blast radius: a controller roll-restarting tenant Deployments is not happening in a PoC; at most an advisory condition.
- Every transition through Updating lands in the timeline, or the demo can't show it.

## Phase 2 - Debate

**Remy (premise challenge):** The tenant doesn't want to change a setting. They want a bigger sandbox. The JIT pitch is *spinning up a fresh environment* - a namespace per demo. The right flow is "create voting-b with different params", and "change" is a fake requirement the annotation shape invites.

**Kira:** The demo story is *this* tenant's environment changing while the app keeps running. A second namespace proves nothing about updates, and the console story (S18-S21) is built on one namespace.

**Ops:** `maxmemory` is a genuine in-environment knob, and the modules expose exactly the settings a tenant would turn.

**Sage:** A postgres_db or password change is not expressible as "new namespace" without data loss. The requirement is real.

**Remy:** Conceded - the requirement stands, but scope it: v1 covers `params` + `softDeleteTTL`; `moduleVersion` is deferred, because the runner ignores it (local modules). Shipping a knob the platform doesn't act on is a lie with a UI.
*Conceded, with a scope cut.*

**Nova -> Ivy:** Your "no anchor" point is the whole game. First-writer-wins compares against stored params but records no writer - with two disagreeing writers, drift detection has nothing to compare against.

**Sage:** Then record it. `status.paramSource` - the Deployment whose annotation the spec reflects. The CRD status schema is a closed list, so it's a one-line CRD addition; the API server would prune it otherwise.

**Ivy:** And define what happens when the paramSource Deployment is deleted. Does a survivor with different params inherit authorship? Yes is a surprise re-apply; no freezes the spec to a ghost's params forever.

**Nova:** No surprise re-apply. The survivor doesn't inherit until the claim re-resolves: paramSource gone → authorship moves to the lexicographically-first surviving writer and the spec syncs to its params. That *is* a re-apply, but it's reconciliation - same class as resurrection (Orphaned → Ready).

**Sage:** And it must be named - a condition on the authorship change, or we've built a second silent path.
*Synthesised into: `paramSource` + explicit re-resolution + condition on authorship change. ("Last-writer-wins" dies here too: event order isn't durable across a controller restart, and the resync backstop would need a deterministic tie-break anyway.)*
*Conceded - candidate for Roads not taken: last-writer-wins authorship.*

**Sage -> Remy:** I want a snapshot of the pre-change params - a failed mid-update should auto-restore the last-good params.

**Remy:** That's a rollback engine for a PoC. The annotation *is* the rollback: edit it back, tofu converges to the old state. MinIO state plus the old params is exactly what the reverse apply needs.

**Ops:** One condition - a half-applied update must not leave the claim un-provisionable, and a failed update must never enter Deleting. No accidental teardown from a bad knob.

**Remy:** Agreed. No snapshot; Failed + message is enough.
*Synthesised into: rollback = re-annotate; failed updates stay in Ready/Failed territory, never Deleting.*

**Kira -> Sage:** A change isn't done until the app sees it. If postgres_db changed, the app's DATABASE_URL is stale until restart. I want the controller to bump a template annotation on referencing Deployments - rolling restart, flow is atomic.

**Ops:** No. The controller rewriting tenant workloads is a new privilege with a new blast radius. A "change maxmemory" that restarts the voting app mid-demo is worse than a documented manual restart.

**Nova:** And it breaks the referrer story - the controller would own rollout state of Deployments it only references.

**Ivy:** Also: which Deployments get restarted when a Secret changes? All of referencedBy, including ones that don't consume the changed key? You're guessing at app intent.

**Kira:** Fine for v1: an advisory `AppRestartRequired=True` condition plus a doc line - "app env vars resolve at container start; restart to pick up." I keep the condition; you get my silence on the auto-restart.
*Synthesised into: advisory condition + doc line; controller-initiated restart → open question.*

**Ivy -> Nova:** Event-only means a missed event (controller restarts between the annotation write and the watch) is a permanent no-op. That's the bug class I'm here to kill.

**Nova:** The resync backstop exists for exactly that - S12 proved the pattern for orphaning. The 30s tick does the same comparison and converges.

**Sage:** And the resync comparison must use the same `_normalize_params` as the conflict check (L598-600), or the two disagree about "equal" and flap.
*Synthesised into: event path for speed, resync for correctness, one normalization function.*

**Ops -> Nova:** Don't reuse Pending for the in-flight state. Pending means "not yet provisioned"; an Updating claim with live traffic must read differently in the console, and resync must not treat it as stale.

**Nova:** Fair - `Updating` it is. Phase is a free string in the CRD, so it's a status patch, not a schema change. And resync must not re-drive a claim an update already owns: same claim lock, and an idempotent re-apply is the fallback when the event was lost.
*Conceded.*

**Sage -> Remy:** At minimum flag replace-forcing changes. The postgres_db demo will wipe the votes table and nobody will understand why.

**Remy:** The classifier is per-module domain knowledge the controller shouldn't own, and it rots the moment a module adds a variable.

**Nova:** tofu already knows - it just doesn't tell the controller.

**Ops:** A pre-apply `tofu plan` pass that detects "replace" is the only honest signal, and that's a runner change I don't want in v1.

**Remy:** So v1 documents it: "a param change may replace the container and lose data." Whether destructive changes get an explicit acknowledgement gate is a question, not a feature.
*Unresolved → open question (Ivy). The classifier dies; the doc line lives.*

## Phase 3 - Final pitches

### Coupling unit

The design ties the desired state's lifetime to the provisioned infra's. **The claim's spec is the coupling unit for reconciliation** - the diff that drives everything is `claim.spec` vs provisioned reality - but **authorship stays on the annotation** (ADR 0001): the spec is a controller-synced projection of the paramSource Deployment's annotation, never tenant-edited.

*Alternative unit:* the tenant edits `InfraClaim.spec` directly - the CR becomes the form. It loses because ADR 0001 puts authoring on the Deployment so the manifest is the version-controlled source, the CR is Namespace-owned and GC'd with it, and the console read model (S18-S21) reads claims as *state*, not a write surface. Making the CR a form re-litigates ADR 0001 to win.

### Concept 1 - Converge (spec sync + re-apply) — Kira/Nova

On the Deployment update event (and the 30s resync as backstop), the controller compares the paramSource annotation's normalized params against `spec.params`; on drift it patches spec, sets `phase=Updating`, re-POSTs the runner (tofu apply converges - in-place where possible, replace where forced), rewrites Secret/Service/EndpointSlice, returns to Ready, and sets `AppRestartRequired` where the Secret change is app-relevant. New: `status.paramSource` (CRD), free-string `Updating` phase, conditions on every give-up.
- **Pros:** annotation stays the single source of truth (ADR 0001 intact); self-healing (resync backstop); no runner changes (`POST /v1/runs` is already create-or-update); rollback = re-annotate.
- **Cons:** drift detection is a second state machine atop the orphan/TTL one - more silent-no-op surface (Ivy's bug class); replace-forcing changes wipe data with no warning (no classifier in v1); a 600s runner call inside a kopf handler blocks other events.
- **Effort:** M (~3-4 days, assumed)
- **Touches:** `jit-controller/main.py`, `deploy/crd/infraclaim.yaml`, `scripts/checks/S22.sh` (new), `docs/build-plan.md` + `docs/todo.md`, `docs/designs/jit-infra-flows.md`, `docs/designs/annotation-to-state.md`, `app/docs/MANUAL-TESTING-GUIDE.md`

### Concept 2 - Reclaim (destroy-and-recreate on change) — Remy

Detect drift the same way, but the flow is Deleting → re-Pending: destroy the module's infra, keep the IP (`allocatedIP` stays on the claim), re-apply with new params. Both halves are paths the checkpoint suite already hammers (S10-S17).
- **Pros:** smallest new logic - both halves proven; unambiguous semantics ("a change is a new infra"); uniform, documented data-loss behaviour, no in-place/replace subtlety.
- **Cons:** every change destroys postgres and redis state - a heavy price for a knob; downtime gap between destroy and re-apply (pgadmin pointing at dead postgres in the gap); a failed destroy strands the claim in the same zombie territory S17 fought.
- **Effort:** S (~1-2 days, assumed)
- **Touches:** `jit-controller/main.py`, docs

### Concept 3 - Update API (imperative) — Ivy

The annotation holds desired state but the controller never auto-converges: the tenant (or a console target) explicitly triggers an update that re-applies the claim's spec. Editing the annotation stages; running the verb applies.
- **Pros:** one explicit, auditable verb in the timeline; no drift-detection state machine, hence no silent-no-op class; trivially testable (call verb, assert convergence).
- **Cons:** two sources of truth in practice (annotation edited, update never run -> drift, and nothing tells the tenant); the console allowlist is frozen by S18's check, so a new target + surface; missed runs are silent no-ops in the other direction.
- **Effort:** S-M (~2-3 days, assumed)
- **Touches:** `Makefile`/console allowlist, `jit-controller/main.py` (spec sync only), docs

### Concept 4 - Version Bump (immutable identity) — Sage

A module's config is immutable identity: the tenant bumps `moduleVersion` (or a `configHash`) to change settings; the controller detects the mismatch against the claim and does concept 2's destroy + re-apply keyed on identity change. No param diffing at all.
- **Pros:** zero drift logic - string compare; matches K8s immutable-resource convention (change identity to change the thing); deterministic, trivially testable.
- **Cons:** in-place-updatable knobs (maxmemory) get replace semantics - data loss for a two-character edit; a `configHash` computed from params is a drift detector in disguise, so the complexity returns; `moduleVersion` is ignored by the runner today, so the bump means something the platform can't act on.
- **Effort:** S (~1-2 days, assumed)
- **Touches:** `jit-controller/main.py`, annotation convention + docs

## Vote

| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | Annotate-and-done, reversible, visible in the timeline. |
| Nova | 1 | Reuses the create path; the resync backstop is S12-proven. |
| Sage | 1 | Only concept with an observable in-flight state; paramSource makes authorship a fact. |
| Ivy | 3 | The explicit verb is testable; 1's drift state machine is where the silent no-op lives. |
| Remy | 2 | 2 ships in two days on proven paths; 1's extra logic is PoC tax I don't see yet. |
| Ops | 1 | 1's failures stay in Ready/Failed territory; 2 routes every change through the zombie-prone Deleting path. |

Result: **1 - Converge (4-1-1).** Dissent: Ivy (still thinks 3 is the only testable one), Remy (concedes only because 2's data-loss on maxmemory breaks the demo story).
