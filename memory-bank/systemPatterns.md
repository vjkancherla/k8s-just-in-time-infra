# System Patterns

## Architecture
Tenants annotate Deployments → controller watches Deployments, creates a CRD "claim" with an
ownerReference → Namespace. The out-of-cluster runner (Terraform) provisions containers on the
k3d network; the controller writes Secret + Service + EndpointSlice. Two triggers drive
cleanup: soft (Deployment disappears → Orphaned + expiresAt TTL) and hard (Namespace delete →
GC + finalizer → immediate destroy). MinIO holds per-namespace Terraform state.

## Patterns
- One step at a time (build-plan.md); every step ends in a PASS/FAIL checkpoint — run and
  pasted, never described.
- Simplest thing that passes the checkpoint; no new deps unless the step names them.
- A failed checkpoint stops the step; two failures → stop and report, no third attempt.
- Checkpoint scripts: `set -euo pipefail`, print PASS/FAIL, exit non-zero on failure.
- Read only the files a step lists; tick the todo.md box only after its checkpoint printed PASS.

## Decisions
- Authoring on the Deployment (tenant-writable); ownership via ownerReference → Namespace
  (survives churn). See docs/decisions/.

