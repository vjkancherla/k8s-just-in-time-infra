# 0001. Annotation on Deployment, ownership on Namespace

Date: 2026-09-01
Status: accepted

## Context

Tenants need to declare infrastructure needs (Redis, Postgres, pgAdmin) alongside their
applications. Three prior versions tried different surfaces:

- **v1**: Modules baked into the controller image — credentials end up in-cluster, modules
  stop being versioned.
- **v2**: Annotation and ownership both on the Deployment — broke because a Deployment is
  a spec revision, not an application; rollouts churn the object.
- **v3**: Annotation on the Namespace — coherent but unusable because tenants cannot edit
  namespaces (stated convention: namespaces are managed by the platform team, not tenants).

The PoC also enforces one namespace per app, and the stated production convention is that
the platform team owns namespaces.

## Decision

Tenants annotate their **Deployments**. The controller creates InfraClaim CRs owned by
the **Namespace** (via `ownerReference`). The annotation is the only thing a human writes;
the claim is derived state.

Cleanup is two-speed:
- **Soft**: Deleting a Deployment marks the claim `Orphaned` with `expiresAt = now + TTL`.
  Infra keeps running. Redeploy within the window resurrects the same containers.
- **Hard**: Deleting the Namespace triggers Kubernetes GC → finalizer → immediate destroy.
  The platform team deleting a namespace is an unambiguous act.

## Consequences

- **Easy**: Tenants declare infra next to their workload, in a place they already have
  write access. Rollouts (delete + recreate Deployments) cost nothing — the claim survives.
  The two-speed cleanup lets the platform team distinguish "app redeployed" from "app
  decommissioned."
- **Hard**: The controller must watch both Deployments (for the annotation) and Namespaces
  (for GC triggers). The resync must correlate Deployments to claims by namespace.
- **Ruled out**: Annotation on Namespace (tenants can't write it). Deployment-owned claims
  (break on rollout). Single-speed hard delete (rollouts become data-loss events).

Supersedes: [v1](./jit-infra-poc-v1-superseded.md), [v2](./jit-infra-poc-v2-superseded.md),
[v3](./jit-infra-poc-v3-superseded.md). See the [design note](../jit-infra-poc.md) for the
full rationale.