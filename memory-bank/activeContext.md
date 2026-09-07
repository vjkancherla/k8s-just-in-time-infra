Updated: 2026-09-07

## Current focus
S09: Resync computes `referencedBy`

## Current work
S08 checkpoint passed. Kopf controller now correctly creates InfraClaims on annotated Deployments.

## Recent changes
- Fixed KUBERNETES_SERVICE_HOST env var override (was pointing to wrong host IP)
- Added verify_ssl=False to kubernetes client config for k3d self-signed certs
- Set priority=100 on custom login ConnectionInfo to beat built-in handler
- Created jit-controller/Dockerfile
- Fixed requirements.txt (was kopf==0.10.2, now kopf>=1.44)
- Added kopf.run(namespaces=["default"]) to fix cluster-wide warning

## Next step
Implement S9: periodic resync (30s) that computes status.referencedBy from live Deployments.

## Blocked
none
