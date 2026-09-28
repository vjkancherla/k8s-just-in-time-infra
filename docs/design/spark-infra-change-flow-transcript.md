# Infra settings-change flow - Brainstorm Transcript
Date: 2026-09-27
Team: Kira, Nova, Sage, Ivy, Remy, Ops (Milo swap for infra/platform)
Context read: jit-controller/main.py, jit-runner/main.py, deploy/crd/infraclaim.yaml, jit-modules/modules/redis/variables.tf, jit-modules/modules/postgres/variables.tf, docs/designs/jit-infra-flows.md, docs/designs/annotation-to-state.md, docs/designs/runner-api.md. Missing: docs/design/infra-change-flow-brainstorm.md (memory-bank 2026-09-26 claims it exists; docs/design/ is empty on disk - treated as unverified, not a constraint).
Decision: see [infra-change-flow-brainstorm.md](./infra-change-flow-brainstorm.md)

## Phase 1 - Free ideation

**Kira**
- Edit the annotation, controller converges in place. No new YAML to learn, app keeps working.
- Console shows update progress (Updating spinner); tenant never touches the claim directly.

**Nova**
- Kira's "edit annotation converges" is taken, so mine is different: reuse the create path - spec-sync on Deployment event + 30s resync, then re-POST. No second loop.
- Stamp last-applied params into `status` so resync is a cheap string compare, not a re-apply every tick.

**Sage**
- Flip the ownership: annotation is the bootstrap default, the Claim spec is the tuning API (RBAC-gated). Direct `kubectl edit infracclaim` for operators.
- Hash normalized params into status (`observedParams`) + per-claim lock already exists (`claim_lock`) to serialise concurrent writers.

**Ivy**
- Make every update destroy+recreate behind one phase. One assertion to test: endpoint changes exactly once.
- Refuse data-loss plans: if tofu wants to replace the volume/container, stay on old outputs and mark Failed.

**Ops**
- In-place re-apply keeping IP + container name (`{ns}-{module}-{module}`); patch Secret/Service only after runner success. Failed update never touches live objects.
- Failed updates keep serving old Secret; rollback = re-annotate with old value, same mechanism as forward.

**Remy**
- Disallow tuning in v1: annotation immutable once Ready; change = delete + recreate namespace. Document it, ship nothing.
- If we must, allow exactly one knob (`redis maxmemory`, default `256mb` sourced from `variables.tf`) as the v1 update path; everything else recreates.

## Phase 2 - Debate

**Remy -> all:** You are solving a problem the demo does not have. Tenants get redis/postgres/pgadmin with working defaults; nobody asked for `maxmemory` tuning. Immutable infra, recreate to change, is the whole PoC philosophy. Why build an update machine for a demo?

**Kira:** Because the demo dies the first time someone asks "can I bump memory?" and we say "delete your namespace". That is homework, not delight.

**Sage:** And the code already half-promises it - `check_param_conflict` first-writer-wins assumes params can differ across writers. Immutable would mean deleting that, not keeping it.

**Ops:** Concede part of Remy's point - most param changes in this stack are destroys in disguise (password rotation, `postgres_db` rename = new DB). But `maxmemory` is a live `tofu apply`, no container replace. Banning all updates to avoid the hard ones is scope-cutting the question, not the plan.

*Unresolved in part -> open question: static allowlist vs tofu-plan inspection for safe-vs-destroy. Premise challenge answered: proceed with an update flow, v1 scoped to safe params.*

**Sage -> Nova:** Annotation as sole source of truth breaks the moment two Deployments share a claim with different params - which `check_param_conflict` already reports. Claim-spec-as-API fixes ownership: one object, RBAC, `kubectl diff`.

**Nova -> Sage:** That is two APIs for one thing. Tenants already write annotations; operators editing claims bypass the lease model (annotation = keep-alive). Your "one object" orphans the resync's `referencedBy` logic - claim with no refs but edited spec, what does it do?

**Sage:** It stays Ready with the edited spec - refs are liveness, spec is desired state. Orthogonal.

**Nova:** Then a redeploy of any Deployment overwrites the operator's edit on next event if you sync annotation->spec. Either annotation wins (your edit is lost) or claim wins (annotation lies). Pick one.

**Sage:** ...Annotation wins on conflict, claim edit is stomped. That kills my concept as a primary.

*Conceded - synthesised into Concept 1: annotation is source of truth; claim spec is a synced copy.*

**Ivy -> Ops:** "Patch Secret only after success" is untestable unless you define success. Runner returns `status: success` with outputs parsed from `tofu output` - sensitive `url` renders `<sensitive>`, which is why the controller re-injects `POSTGRES_PASSWORD`. What does "success" mean for an update that changes only `maxmemory`? Same outputs, new container state, Secret looks unchanged. Your test asserts nothing.

**Ops:** Success = runner 200 + `status success` + outputs present; Secret gets re-patched even if bytes are identical, and `status.observedParams` advances. The assertion is on `observedParams`, not Secret bytes.

**Ivy:** Then a failed apply that leaves the container half-restarted still reports old Secret as healthy. You need a phase that says "I am mid-update, don't trust Ready".

**Ops:** Fair - new `Updating` phase, or at minimum a condition. Without it the console lies during the 600s apply window (sourced: `requests.post timeout=600` in `call_runner`).

*Synthesised into Concept 1: `Updating` phase + `observedParams`; failed updates stay on old outputs, never go Deleting. Ivy's destroy+recreate stays as Concept 2.*

**Kira -> Remy:** One-knob v1 is a toy. If the mechanism works for `maxmemory` it works for `postgres_db` - artificially gating it ships the mechanism plus a hard-coded exception list to maintain.

**Remy -> Kira:** The exception list is the point. `postgres_password` rotation against a container holding data + `postgres_db` rename = data-loss footguns. One knob ships the demo; all-knobs ships the incident. Effort is not the mechanism, it is the test matrix.

**Ops:** Remy's right about blast radius, wrong about the gate. Gate on behaviour (does tofu replace?), not on param name. Allowlist the modules' safe vars per `variables.tf`, refuse replacement plans.

*Unresolved -> open question: who decides safe-vs-destroy.*

**Nova -> Ivy:** Destroy+recreate is honest but breaks the IPAM contract - `ensure_claim` keeps the address ("moving a live container's IP would break its EndpointSlice", `main.py:214-215`). Recreate with a new container on the same IP races the old `docker rm -f`.

**Ivy:** That is exactly why recreate is better - one code path (destroy infra already exists, `destroy_infra` + `cleanup_k8s_resources`), no new runner endpoint, no cache-busting. The IP stays, the container is replaced. Testable, no new phases.

**Ops:** And every update drops all connections + wipes postgres unless the volume survives - which S17 deliberately made not survive ("a container removal takes its volume", tracker). Recreate on postgres = data loss by default.

**Ivy:** ...Concede for stateful, hold for stateless.

*Conceded in part - candidate for Roads not taken: "recreate is the update". Survives as Concept 2, scoped to stateless / explicit recreate intent, not the default.*

**Sage -> Ops:** App env vars resolve at container start - Secret change without pod restart does nothing. Advisory condition vs controller rolling the Deployment?

**Ops:** Advisory only. Controller restarting tenant Deployments is a privilege escalation (it owns claims, not workloads). Set `AppRestartRequired`, console surfaces it.

**Sage:** Agree, but then "update succeeded" is a lie until restart. `Updating -> Ready` must mean infra converged, with a separate condition for app staleness.

*Synthesised into Concept 1: phase for infra, condition for app.*

## Phase 3 - Final pitches

Coupling unit: the Deployment annotation owns desired state; the InfraClaim spec is a synced copy; the runner workspace `(workspace, module)` owns execution. Alternative - claim owns desired state - loses because two Deployments share one claim and the resync's `referencedBy` lease already treats annotations as keep-alives.

### 1. Converge (annotation -> spec sync -> runner re-apply)
On Deployment event + 30s resync (sourced: `@kopf.timer interval=30`), controller diffs annotation params vs `status.observedParams`; on drift, patches claim spec, sets `Updating`, re-POSTs full params (tenant + name/ip/network + resolved passwords), patches Secret/Service/EndpointSlice only on success, advances `observedParams`. Failures keep old outputs, never enter `Deleting`. Rollback = re-annotate. App staleness = advisory `AppRestartRequired`; controller never restarts pods.

### 2. Recreate (destroy + create as the update)
Any drift triggers `destroy_infra` + `cleanup_k8s_resources` + fresh `provision_infra` on the same IP. One code path, no runner apply semantics to debug.

### 3. Claim-as-API (spec edit, annotation frozen after bootstrap)
Edit `InfraClaim.spec.params` directly; controller watches spec generation and re-applies. Annotations ignored after creation. RBAC-gated.

### 4. Blue-green claim (new workspace, flip Service)
On drift, provision `{ns}-{module}-v2` (new IP from block of 10, assumed pressure at 3+ parallel updates), cut Service/EndpointSlice over on success, destroy old.

## Vote
| Agent | Vote | Why |
|---|---|---|
| Kira | 1 | Only option where tenant never learns a second object. |
| Nova | 1 | Reuses create path; cheapest correct mechanism. |
| Sage | 1 | Annotation-wins + observedParams closes the two-writer hole I opened. |
| Ops | 1 | Keeps identity + Secret atomicity; recreate wipes data. |
| Ivy | 2 | Still thinks 1's "success" is untestable without a replace-refusal gate; 2 is the only falsifiable update. |
| Remy | 1 | Smallest shippable that answers the premise; ties break to scope. |

Winner: Concept 1 (Converge), 5-1. Unmade case: nobody priced Converge's 600s handler block vs Blue-green's IP exhaustion.
