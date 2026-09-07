Updated: 2026-09-07

## Working
S0-S8: All prior checkpoints pass.

## Done (verified)
- S0-S7: All prior checkpoints pass
- S08: CRD + claim creation, ownerRef → Namespace, finalizer ✅

## In progress
- S09: Resync computes referencedBy

## Blocked
none

## Learnings
- kopf 1.x login vault selects credentials by MAX priority on ConnectionInfo
- KUBERNETES_SERVICE_HOST env var overrides in-cluster config server URL
- k3d API server is not at hostIP:443 — use default ClusterIP instead
- k3d image import doesn't always replace cached images; remove old image ID first
- kopf handler annotations on the resource track retries and error messages
- requirements.txt had stale version (kopf==0.10.2 doesn't exist on PyPI)
