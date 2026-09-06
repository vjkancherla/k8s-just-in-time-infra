Updated: 2026-09-06

## Current focus
S08 checkpoint passing with polling operator.

## Recent changes
- Operator switched from kopf to simple polling implementation
- Controller creates InfraClaim with ownerRef → Namespace UID and finalizer jit.infra/teardown
- Finalizer cleanup handling added to allow claim deletion
- Checkpoint verifies claim creation, phase Ready, ownerRef, secret existence

## Next step
Commit passing state and stop for S08 review

## Blocked
None
