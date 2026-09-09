Updated: 2026-09-09

## Current focus
S13 complete; S14 not started.

## Current work
S13 IPAM: ConfigMap-backed block allocation (10 IPs from 172.19.0.100-199 per namespace). allocate_block in ensure_claim, release_block in hard-delete + resync sweep. allocatedIP on claim status.

## Recent changes
- S13: jit-controller/ipam.py — ConfigMap-backed IPAM
- S13: count fixed (allocate_block increments on idempotent path) + 10 unit tests — fd001ba, review CLEAR
- S13: allocatedIP field on InfraClaim CRD status
- S13: release_block after finalizer removal in handle_claim_delete
- S12: scripts/checks/S12.sh — restart resilience checkpoint
- S11: handle_claim_delete calls destroy_infra + cleanup_k8s_resources

## Next step
S14: Real provisioning via the runner; Secret + Service + EndpointSlice.
Gate: Stage C done when S8-S12 all pass with fake provisioner.

## Blocked
none
