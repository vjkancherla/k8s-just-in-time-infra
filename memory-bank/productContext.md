# Product Context

## Problem
K8s infra (databases, caches) is either long-lived and wasted, or deleted and lost. A
Deployment rollout that deletes and recreates a pod looks like data loss, so rollouts
become frightening.

## Users
- Tenants: annotate their Deployments to request infra; they cannot edit Namespaces.
- Platform team: owns Namespaces and their lifecycle/teardown.

## Behaviour
- Annotate a Deployment → claim created, owned by the Namespace → containers scheduled on the
  k3d network (e.g. redis at .10x).
- Delete the Deployment → claim Orphaned, `expiresAt = now+TTL`, infra keeps running and data
  survives; redeploy inside the window resurrects the same containers.
- Delete the Namespace → immediate destroy via GC + finalizer.

