Updated: 2026-09-09

## Current focus
S12 complete; S13 not started.

## Current work
S12 checkpoint script verifies controller restart resilience: scale to 0, delete Deployment, scale back to 1, claim becomes Orphaned within resync interval. No code changes to main.py needed — resync timer already handles this.

## Recent changes
- S12: scripts/checks/S12.sh — restart resilience checkpoint (scale-to-0, delete, scale-back)
- S11: handle_claim_delete calls destroy_infra + cleanup_k8s_resources
- S11: WATCH_NAMESPACES env var for configurable namespace watching
- S10: Deleting phase, destroy guard, JSON Patch expiresAt, RUNNER_TOKEN

## Next step
S13: IPAM — allocate/release IPs for infra modules.
Gate: Stage C done when S8-S12 all pass with fake provisioner.

## Blocked
none
