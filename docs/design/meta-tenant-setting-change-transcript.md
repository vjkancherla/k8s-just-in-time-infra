# Tenant setting change – Brainstorm Transcript

Date: 2026-09-26
Participants: Kira, Sage, Remy, Ivy, Milo, Juno

## Phase 1 – Framing

**Kira:** Current flow is annotation → controller → runner → infra → Secret. Tenant can create infra, but we have no story for changing settings on live infra. The open question in the design is annotation edit: re-apply or refuse?

**Sage:** The split authoring/ownership model means tenants only write Deployments. If we allow annotation drift, we need a deterministic reconciliation rule. Otherwise we get silent divergence.

**Remy:** Scope check: is this a PoC problem? In production you'd have a CRD with status conditions and an update controller. Here we have a single annotation string. Are we solving a real user need or adding complexity for a demo?

**Ivy:** Real need. The demo shows `ALLOW_MULTIPLE_VOTES` toggle. Tenants will ask “can I bump redis memory?” If we say “delete and recreate”, that's a data loss story we need to be explicit about.

**Milo:** Simplest is immutable. Annotation change = new desired state. Controller converges by recreating. That's what Kubernetes does for most resources.

**Juno:** But Kubernetes also does in-place updates for Deployments. Tenants expect the same mental model: edit, apply, thing changes.

## Phase 2 – Challenges

**Sage:** Recreation destroys state. Redis queue loss is acceptable for a PoC? Postgres data loss is not.

**Kira:** Agreed. We need a guard. Maybe differentiate stateless vs stateful modules. For redis, recreate is okay with a warning. For postgres, refuse unless `forceRecreate=true`.

**Ivy:** That guard is policy, not mechanics. The mechanics still need diff detection. Today `handle_deployment` only ensures claim exists. We need to compare annotation to claim.spec.

**Remy:** That comparison is fine, but it introduces a new state transition: `Ready → Updating`. We don't have that in the state machine. Adding it increases test surface.

**Milo:** Could we avoid a new state? Just treat change as delete + create. The claim is owned by Namespace, so we can destroy and provision with same name. The resync loop will see the Deployment still referencing it, so it will immediately re-provision.

**Juno:** That's a hidden loop. The controller would see reference exists, so it would not orphan. If we destroy first, we lose IP. The Secret updates, pods restart. It's okay but noisy.

**Sage:** Runner update is cleaner. Terraform can update a redis container's memory limit without destroy. Why not call runner with updated params?

**Kira:** Runner today is create-only in PoC. `POST /v1/runs` creates workspace, `DELETE` destroys. No PATCH. Adding update means runner API change, Terraform state handling, and rollback on failure.

**Ivy:** Effort estimate matters. PoC has 18 steps, each with a checkpoint. Adding runner update is M/L effort, needs new checks.

**Remy:** Premise challenge: do we need in-place updates at all? The PoC demonstrates JIT provisioning and two-speed cleanup. Settings change is out of scope for the current build plan. We could document “change requires recreate” and close the issue.

**Juno:** But the open question in jit-infra-poc.md explicitly asks about annotation edited on live Deployment. That's a design debt.

**Milo:** Could we defer to a separate Settings object later? For now, document the limitation.

## Phase 3 – Concepts

The team converged on four concepts:

A. Immutable annotation → recreate on change, with stateful guard.
B. Diff-driven in-place update with opt-in flag.
C. Explicit update annotation with revision.
D. Versioned module pin with redeploy.

## Vote

- Kira: A – matches PoC simplicity, guardrails acceptable.
- Sage: B – wants real updates, but acknowledges effort.
- Remy: A – scope control, PoC stays PoC.
- Ivy: A with guardrails – acceptance criteria clear.
- Milo: A – simplest thing that passes checkpoint.
- Juno: C – prefers explicit intent, but A is acceptable for PoC.

Vote 4-1-1 for A, with dissent from Sage on untestable update semantics and Juno on lack of explicit intent.

**Open questions logged:**
1. How to classify stateful vs stateless modules without hardcoding?
2. Should `softDeleteTTL` changes be allowed in-place?
3. What is the observable signal to tenant that a recreate happened?

## Decision
Proceed with Concept A for PoC: annotation diff detection triggers recreation, stateful modules require `forceRecreate=true`, documented limitation. In-place update deferred to post-PoC.

Transcript linked from `docs/design/tenant-setting-change-brainstorm.md`.
