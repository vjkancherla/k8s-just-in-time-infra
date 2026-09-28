# Infra settings change - Team Brainstorm
Date: 2026-09-27
Reviewed: consilium 2026-09-27 - 3 blockers fixed, 2 risks in Open questions
Team: Kira, Nova, Sage, Ivy, Ops, Remy
Premise challenge: Remy
Context read: jit-controller/main.py, jit-runner/main.py, deploy/crd/infraclaim.yaml, jit-modules/modules/{redis,postgres}/{main.tf,variables.tf}, docs/designs/{annotation-to-state,runner-api,jit-infra-flows,jit-infra-poc}.md, docs/decisions/0001-annotation-on-deployment-ownership-on-namespace.md, app/kustomize/base/vote-deployment.yaml, docs/design/ (empty)
Full debate: [infra-change-flow-transcript.md](./infra-change-flow-transcript.md)

## Decision
**Concept 1 - Converge.** The Deployment annotation stays the only write surface (ADR 0001). After first Ready, a change to the param-winner's `params` (or a TTL-only edit) is projected onto `InfraClaim.spec` and, for params, re-applied with `POST /v1/runs`. No new claim phase: conditions `Updating` / `UpdateFailed` only. Rollback is re-annotate. v1 demo is redis `maxmemory`.

Remy's premise (JIT infra is throwaway; do not mutate) lost on the SoT-lie argument, not on "tenants love pets". Drift-only (Concept 2) is the recorded dissent.

Consilium (same roster, after the note was written): lastAppliedParams is tenant `spec.params` only, not the runner payload (`name`/`ip`/`network`/generated password) — otherwise skip-if-equal never matches the annotation. Stamp it on first Ready, not only on update, or the first resync looks like drift. Spec patch follows the param-winner rules; a loser Deployment event must not write spec. AC1 no longer requires observing `Updating=True` on a fast apply (unfalsifiable).

## Concepts

### 1. Converge  *(selected)*
Annotation is desired state; claim.spec is a projection; MinIO terraform state is actual. Three freeze-points currently ignore annotation edits after first apply: `ensure_claim` 409 (main.py:205-208), `provision_infra` Ready+Secret skip (main.py:299-306), runner success-cache that ignores params (jit-runner/main.py:211-213). Unstick all three. Skip-if-equal on `status.lastAppliedParams` keeps rollouts cheap. First-writer-wins survives: the winner changing their mind, or remaining refs agreeing, is the update; a loser's edit is still `ParamsConflict`.
- **Pros:** Makes ADR 0001 true after first apply. Reuses `POST /v1/runs` (already create-or-update at tofu). Postgres volume is not destroyed (`tofu apply` leaves `docker_volume.postgres_data` alone).
- **Cons:** Redis `command` includes `--maxmemory` (redis/main.tf:30) so the demo replace is ForceNew at the provider — not in-place. Dual-writer update is easy to get wrong. A 600s kopf handler (call_runner timeout, main.py:488) can stall other events; the 30s resync (main.py:815) is the backstop.
- **Effort:** M (assumed ~3-4 days: controller winner-sync + lastApplied + conditions, runner cache compare, CRD field, checkpoint covering AC1–6)
- **Touches:** jit-controller/main.py, jit-runner/main.py, deploy/crd/infraclaim.yaml, docs/designs/jit-infra-flows.md (Ready+conditions note, no new phase)

### 2. Drift-only (immutable claims)
After first Ready the claim is frozen. Winner's annotation params ≠ last-applied → `AnnotationDrift`. No POST. Tenant takes the new params only by destroying (soft TTL or namespace).
- **Pros:** Smallest code. Most testable. No container replace from a JSON blob.
- **Cons:** Annotation keeps lying until destroy. Soft-delete still ends in `tofu destroy`, which deletes `docker_volume.postgres_data` (postgres/main.tf:21-25). "Change maxmemory" becomes "wait 10m (vote-deployment.yaml) and lose data".
- **Effort:** S (assumed ~0.5-1 day)
- **Touches:** jit-controller/main.py; CRD only if lastApplied is added rather than comparing frozen spec

### 3. Recreate
Param change is `DELETE /v1/runs` then `POST`. Honest container death. Keep `allocatedIP` so the EndpointSlice stays.
- **Pros:** Blast radius is explicit. No ForceNew surprises.
- **Cons:** `tofu destroy` deletes the postgres volume. Recreate-as-default is data loss. Redis-only recreate is Concept 1 with extra downtime.
- **Effort:** M (assumed ~2 days)
- **Touches:** jit-controller/main.py, jit-runner/main.py

### 4. Generation-gated
Converge, but apply only when a mutate-generation annotation increments.
- **Pros:** Accidental JSON reshuffles cannot replace a container. Gives Sage a refuse-path for `postgres_db`.
- **Cons:** A second write protocol on top of the annotation. Tenants will forget the generation and file "annotate does nothing". Skip-if-equal already covers rollouts that do not change params.
- **Effort:** L (assumed ~3-4 days: Concept 1 plus schema, docs, demo)
- **Touches:** Concept 1 plus annotation schema and demo manifests

## Debate highlights
- **Remy vs Kira on the premise:** Remy called mutate petting cattle. Kira: ADR 0001 is already a lie after first apply; gitops will write 128mb and Redis stays 256mb (variables.tf default). *Resolved:* not a new API; repair the SoT. Remy conceded the requirement, not the scope (no phase; cut moduleVersion / postgres_db / passwords).
- **Ops vs Nova on Updating-as-phase:** 600s handler looks dead without a phase. Nova: Failed-as-phase is initial provision; a new phase rewrites jit-infra-flows.md §4. *Resolved:* conditions only, set before POST, cleared on success.
- **Ivy vs Nova on first-writer-wins:** vote updates, worker still `{}` — flip-flop or ignore? *Resolved:* winner-changed-mind and unanimous remaining refs apply; loser still ParamsConflict. Ivy voted 2 until that is a checkpoint.
- **Sage vs Kira on generation:** rollouts conceded (skip-if-equal). Destructive params (`POSTGRES_DB` is init-only, postgres/main.tf:59) unresolved — see Open questions.
- **Ops vs Remy on Recreate:** destroy deletes the volume. *Killed* as default.

## Roads not taken
- **Claim as immutable unit** (Remy, Concept 2): the change-unit is replacement, not mutate. Strongest case: JIT already sold two-speed cleanup; a drift condition is honest. Lost because silent annotation-vs-container disagreement is the thing tenants will hit, and destroy is the wrong tool for maxmemory. Would win if we decided claims are write-once.
- **InfraClaim.spec as the write surface:** tenants do not author the CR (ADR 0001) and cannot edit the Namespace. Coupling unit stays the Deployment annotation.

## Vote
| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | Annotation is already the write path. Drift-only leaves the SoT lying. |
| Nova | 1 | Three freeze-points. Smallest code that makes ADR 0001 true. No phase. |
| Sage | 4 | Destructive params need a gate. Skip-if-equal does not refuse postgres_db. |
| Ivy | 2 | Dual-writer update is the untestable bit. Would move to 1 if the checkpoint names winner-vs-loser. |
| Ops | 1 | Recreate destroys docker_volume. tofu apply is the smaller blast radius; demo must say Redis is replaced. |
| Remy | 2 | Premise still stands for apply. Drift-only ships. Tie-break unused. |

3-2-1 for Converge. Dissent stands: Ivy on the dual-writer checkpoint, Sage on destructive params, Remy on "do not apply".


## Behaviour (selected)

Desired-state compare key is `status.lastAppliedParams` (new CRD status field; closed schema, so infraclaim.yaml must list it or the API server prunes it). Shape is tenant `spec.params` only — not the runner payload (`name` / `ip` / `network` / generated `postgres_password`). Comparing against the runner payload would never match an annotation. Stamp it on first Ready, not only on later updates, or the first resync looks like drift. Not claim.spec — once we patch spec, spec==desired is tautological.

Param winner, in order:
1. Among current refs, the Deployment whose params match lastApplied (the original writer, still present) — their new annotation is the update.
2. Else if every remaining ref agrees on one params object, that object.
3. Else do not apply; keep ParamsConflict.

TTL-only (`softDeleteTTL` change, params equal lastApplied): patch spec from the same winner rules, no POST. A loser Deployment event must not write spec — that is last-writer-wins by accident (`ensure_claim` today is create-only on 409, main.py:205-208; the 409 path grows a *winner* patch, not an unconditional one).

On param drift: set `Updating=True` *before* `POST /v1/runs` (observability for a hang; a fast apply may clear it before a poller sees True — do not assert the True edge). Runner compares the full request params to the cached run; match → return cache; differ → `tofu apply`. Success: rewrite Secret, write lastAppliedParams to the tenant params that were sent (not the runner overlay), clear Updating and UpdateFailed. Failure: phase stays Ready (container still serving), `UpdateFailed=True`, never Deleting. Resync (30s) retries Failed-update; it must not retry initial Failed (main.py:849-853 still holds).

In-flight: `ensure_claim` may patch spec without `claim_lock` today (main.py:150-152). Re-read spec under the lock before POST. One apply per handler. If spec moved, leave Updating set; resync is the backstop.

Out of v1: `moduleVersion` (runner `version` unused, runner-api.md), tenant updates to `postgres_password` (controller-owned, postgres/main.tf:45-52), console write path (0004, read model), undo stack (re-annotate is rollback).

Demo: redis `maxmemory`. Say in the walkthrough that the container is replaced. Do not demo `postgres_db`.

## Acceptance criteria
Falsifiable. Each is a checkpoint assertion, not an intention.

1. Patch the winner Deployment's `jit.infra/redis` params to `{"maxmemory":"128mb"}`. Within one 30s resync tick plus one runner call: claim.spec.params.maxmemory is `128mb`, `Updating` is not True, `status.lastAppliedParams.maxmemory` is `128mb`, the redis container command contains `--maxmemory 128mb`.
2. Patch only `softDeleteTTL` on the winner. Claim.spec.softDeleteTTL updates. No new `tofu apply` (container ID unchanged). `Updating` is not True.
3. Two refs. Patch the loser's params. `ParamsConflict` is True. lastAppliedParams and container command unchanged. Then patch the winner to the same new params: criterion 1 holds and ParamsConflict clears.
4. Induce a runner failure on an update (bad param or runner down). Phase remains Ready. `UpdateFailed=True`. Claim is not Deleting. Secret still has data.
5. Re-annotate the previous params. Criterion 1 in reverse (command back to `256mb`, the module default in redis/variables.tf).
6. Rollout that does not change jit.infra params (annotation JSON identical). No POST, container ID unchanged.

Give-up: if the runner is unreachable or apply errors, `UpdateFailed` is set within one 30s resync tick of the handler returning. No silent skip.

## Open questions
- [ ] Mutable-param policy for anything other than redis maxmemory / TTL: allowlist, tofu-decides, or `UpdateBlocked`? Sage's postgres_db case. (Sage, Ops)
- [ ] Dual-writer checkpoint in the S22 check script — Ivy votes 2 until it exists. Treat criterion 3 as load-bearing, not optional. (Ivy)
- [ ] App pods read env at start. Redis maxmemory does not change Secret keys, so no restart. If a later param *does* change Secret data, is `AppRestartRequired` advisory, or out of scope until then? (Kira, Ops)
- [ ] How AC4 induces a runner failure without leaving the cluster wedged (stop the runner? send a tofu-invalid var?). Checkpoint must restore Ready afterwards. (Ivy)
- [ ] Claims already Ready before this ships have empty lastAppliedParams. First resync after upgrade would look like drift and re-apply. Stamp-on-Ready covers new claims; existing ones need a one-shot "treat missing lastApplied as current spec" or a recreate. (Ops)

## Next steps
- [ ] Add S22 to `docs/build-plan.md` and `docs/todo.md` with the six criteria above as the checkpoint.
- [ ] Implement runner cache compare first (without it, lastAppliedParams lies).
- [ ] Then controller: winner-only spec patch on 409 (not unconditional), skip-if-equal vs lastAppliedParams (tenant params), stamp lastAppliedParams on first Ready, Updating/UpdateFailed, CRD `status.lastAppliedParams`.

