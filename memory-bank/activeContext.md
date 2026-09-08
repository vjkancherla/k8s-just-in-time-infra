Updated: 2026-09-08

## Current focus
S10 complete; S11 not started.

## Current work
S10 (soft delete — orphan and expiry) implemented and checkpoint PASS.

## Recent changes
- S10: resync timer now handles Ready↔Orphaned transitions + TTL sweep
- S10: parse_ttl for softDeleteTTL (s/m/h/d), destroy_infra calls runner DELETE
- S10: cleanup_k8s_resources removes Secret/Service/EndpointSlice
- S10: ensure_ready clears expiresAt on resurrection
- S10: added logging.basicConfig, requests dep, PYTHONDONTWRITEBYTECODE=1

## Next step
S11: hard delete — namespace deletion destroys immediately, regardless of expiry.
Claim has ownerRef → Namespace, so GC deletes it; finalizer handler runs destroy.

## Blocked
none
