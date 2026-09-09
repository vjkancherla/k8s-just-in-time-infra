Updated: 2026-09-09

## Working
none this session (S12 done).

## Done (verified)
- S0-S8: All prior checkpoints pass
- S09: checkpoint PASS → committed 5d02813, review CLEAR
- S10: checkpoint PASS → committed 1063f4d, findings addressed in 6d1554e
  - Deleting phase, destroy guard, redundant patch, JSON Patch expiresAt, RUNNER_TOKEN
- S11: checkpoint PASS → committed 96312f7
  - hard delete: destroy_infra+cleanup in handle_claim_delete, WATCH_NAMESPACES env var
- S12: checkpoint PASS — no code change, only checkpoint script (resync already handles restart)

## In progress
none — S13 (IPAM) not started. Gate: Stage C done when S8-S12 all pass.

## Blocked
none

## Learnings
- kopf 1.x login vault selects credentials by MAX priority on ConnectionInfo
- KUBERNETES_SERVICE_HOST env var overrides in-cluster config server URL
- k3d API server is not at hostIP:443 — use default ClusterIP instead
- k3d image import doesn't always replace cached images; remove old image ID first with crictl rmi
- kopf handler annotations on the resource track retries and error messages
- requirements.txt had stale version (kopf==0.10.2 doesn't exist on PyPI)
- @kopf.timer with interval=30 initial_delay=True gives a reliable 30s resync cadence
- strategic merge patch cannot remove status fields; use empty string sentinel for "cleared"
- k3d image import is flaky on first attempt; retry once if it fails
- Python __pycache__ can persist across image layers; use PYTHONDONTWRITEBYTECODE=1
- logging.getLogger() without basicConfig has no handlers when running via python (not kopf CLI)
- kopf Body object is not a plain dict; pass plain dicts to kubernetes client patch calls
