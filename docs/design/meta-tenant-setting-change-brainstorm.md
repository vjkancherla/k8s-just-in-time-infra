# Tenant-driven infrastructure setting changes – Brainstorm

Date: 2026-09-26
Context: Current JIT flow: Deployment annotation → controller → JIT runner → provision infra + Secret → app consumes. App works. Open question from design: *Annotation edited on a live Deployment - re-apply, or refuse? Re-apply will recreate Redis and drop the queue.*

## Problem statement
Tenant wants to change a setting on already-provisioned infrastructure, e.g.:
- `params.memory` for redis
- `moduleVersion` or `params.version` for postgres
- `softDeleteTTL`
- any param that maps to Terraform module input

How does a change propagate without breaking the soft/hard lifecycle, refcounting, and the split authoring/ownership model?

## Constraints
- Authoring surface is Deployment annotation only. Tenants have no Namespace write.
- Controller is a reconciler; no admission webhooks in PoC.
- Runner is stateless, calls `tofu apply` with params.
- No new CRD in PoC unless justified.
- Simplest thing that passes checkpoint.

## Concepts explored

### A. Immutable annotation – recreate on change
**Description:** Controller stores the annotation hash in claim.spec. On Deployment update, if annotation differs from stored spec, treat as intentional recreation: move claim to `Deleting`, destroy via runner, release IP, then provision new infra with new params. Resurrection semantics preserved.

**Pros**
- Matches current PoC mental model: annotation = desired spec, controller converges.
- No runner update semantics needed; `tofu apply` with new params is just a fresh workspace.
- Simple to implement: compare `spec.params` + `moduleVersion` to current claim.spec.

**Cons**
- Destructive for stateful modules: Redis queue lost, Postgres data lost unless snapshot.
- IP changes → Secret changes → app pods restart. For redis this is a brief outage.
- Violates expectation of "change setting" = in-place tweak.

**Effort:** S – ~0.5 day
**Touches:** `jit-controller/main.py` handle_deployment, claim ensure logic, `docs/designs/jit-infra-poc.md`

### B. Diff-driven in-place update with opt-in
**Description:** On Deployment update, diff annotation params vs claim.spec.params. If changed and `params.allowUpdate=true` in annotation, call runner with update path: `POST /v1/runs/{workspace}` with updated params, then patch Secret if outputs changed. Claim stays Ready, no destroy.

**Pros**
- Real change propagation, no recreation.
- Keeps IP and data.

**Cons**
- Runner must support update vs create; Terraform can do both but module may need `create_before_destroy` handling.
- State drift risk: if controller crashes mid-update, claim spec and actual infra diverge.
- PoC has no versioning or rollback; a bad param can break app silently.
- Requires storing desired params vs actual params and handling partial failures.

**Effort:** M – ~1.5 days
**Touches:** controller, runner API, state machine, docs

### C. Explicit update annotation – two-step intent
**Description:** Keep annotation immutable for initial provisioning. Tenant changes settings by adding `jit.infra/<module>/update` annotation with a JSON patch and a monotonic `updateRevision`. Controller sees new update annotation, validates, triggers update workflow, then removes the update annotation on success. Original provisioning annotation unchanged.

**Pros**
- Intent is explicit, auditable.
- Prevents accidental drift from normal Deployment re-applies.
- Allows approval gate later.

**Cons**
- New annotation key, more surface.
- Still needs runner update semantics.
- PoC complexity increase.

**Effort:** M/L – ~2 days
**Touches:** controller, docs

### D. Versioned module pin with redeploy
**Description:** Settings changes must go via new `moduleVersion`. Changing params requires bumping version and redeploying Deployment with new annotation. Old claim is orphaned and TTL runs, new claim created. Tenant can control coexistence window.

**Pros**
- Leverages existing refcount and TTL semantics.
- No in-place update complexity.
- Clear data-loss boundary.

**Cons**
- Two infra stacks temporarily.
- Not "change setting", it's "spin up new".

**Effort:** S – documentation only
**Touches:** docs

## Open questions
- Does a Deployment scaled to zero count as present? Currently yes.
- Should Orphaned infra be visible to tenant?
- What is the correct failure mode if runner update fails? Keep old params? Retry?
- Do we want to allow `softDeleteTTL` changes on live claim? That affects expiry.

## Recommendation for PoC
Adopt **A with guardrails**:
- Treat annotation change as a recreation.
- Add a safety check: if `module` is stateful (`postgres`), log a warning and require `forceRecreate=true` in annotation to proceed. Default to refuse update for stateful modules.
- Document that changing settings on stateful infra is a recreate, and tenant must handle data migration outside PoC.

This keeps the PoC simple, matches the existing open question's spirit, and avoids introducing update semantics we cannot verify.

If the human wants true in-place updates, we can move to B in a later step with explicit acceptance criteria and a runner update API.

## Next concrete step
Add annotation diff detection in `handle_deployment`:
1. Parse current annotation.
2. Load existing InfraClaim spec.
3. If spec differs → log, set claim phase to `Updating`, call `destroy_infra` + `provision_infra` with new params, keep same IP if possible.
4. Emit warning for stateful modules.

Verification: `kubectl annotate deploy vote jit.infra/redis='{"module":"redis","moduleVersion":"v1","params":{"memory":"256mb"}}'` should trigger recreation, claim status transitions visible, Secret updated.

---
Reviewed: consilium pending
