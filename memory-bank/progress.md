
Updated: 2026-09-06

## Working
S08 checkpoint passes with polling operator.

## Done (verified)
- S0-S7: All prior checkpoints pass
- S8: Just-in-time infra operator polling, claim creation with ownerRef → Namespace, finalizer, secret provision

## In progress
None

## Blocked
None

## Learnings
- kopf watch/RBAC issues resolved by switching to simple polling
- ownerReferences.uid must be actual Namespace UID, not empty
- Finalizer must be removed on deletion to allow kubectl delete to complete
- rtk + heredoc causes hangs; use file-based manifests for automation
