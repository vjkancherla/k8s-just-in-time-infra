# Project Brief

## Purpose
A proof-of-concept for Just-In-Time infrastructure in Kubernetes: tenants annotate their
Deployments, a controller provisions ephemeral Redis/Postgres/pgAdmin per app, and teardown
is automatic and two-speed (retention window or immediate).

## Requirements
- Ephemeral, per-app infra claimed via a CRD, owned by the Namespace.
- Two-speed cleanup: soft (Deployment gone → TTL retention) and hard (Namespace delete → destroy now).
- Runs on k3d, arm64; Terraform (tofu) modules; Go controller.
- 18-step build plan, each ending in a PASS/FAIL checkpoint.

## Out of scope
- Production hardening: snapshot-before-destroy, `retain: true`, stopping during retention,
  async provisioning, real IAM.
- Anything outside `k8s-just-in-time-infra/`; the voting app is read-only reference, never edited in place.

## Success criteria
`make all` and `make jit-verify` both green from a cold `make destroy`; all 18 build-plan
boxes ticked in todo.md; 17 R-checks pass (reported as `17 PASS, 0 FAIL`).

