# JIT Infra PoC - Tracker

Design: [design/jit-infra-poc.md](design/jit-infra-poc.md)
Steps: [build-plan.md](./build-plan.md)
Rules: [../.clinerules/01-jit-poc.md](../.clinerules/01-jit-poc.md)

Each step has **two** boxes. Tick `check` when the checkpoint printed `PASS`; tick
`review` when a different model wrote `CLEAR` in `docs/reviews/SNN-findings.md`. Paste
the checkpoint output and note the reviewing model under the step.

A step with one box ticked is not done. One step per session.

## Decisions (settled)

- [x] Annotation on the **Deployment** - tenants cannot edit namespaces
- [x] Claim owned by the **Namespace** - survives Deployment churn; one ns per app
- [x] **Two-speed cleanup** - Deployment delete starts a TTL; Namespace delete destroys now
- [x] Redis, Postgres and pgAdmin all on the annotation path; no manual tier
- [x] No snapshot guardrail in the PoC - soft delete covers the accident that matters
- [x] All work in `k8s-just-in-time-infra/`; the voting app is copied into `app/`, never edited in place

## Stage Z - Before anything

- [ ] check  - [ ] review  **S-1** All 18 checkpoint scripts written, all 18 failing, none erroring  ← **then frozen**

## Stage A - Baseline

- [x] check  - [ ] review  **S0** Copy the app, `make destroy`, add `--subnet 172.19.0.0/16`, `make all` = 17 PASS
- [x] check  - [ ] review  **S1** Pod reaches a container by Docker-network IP  ← **hard gate**

## Stage B - Provisioning plane, no Kubernetes

- [x] check  - [ ] review  **S2** MinIO at `.11`, bucket `jit-state`
- [x] check  - [ ] review  **S3** `modules/redis` applies and destroys, state in MinIO
- [x] check  - [ ] review  **S4** `modules/postgres`, data survives container removal
- [x] check  - [ ] review  **S5** `modules/pgadmin` reachable, connects to Postgres
- [x] check  - [ ] review  **S6** `jit-runner` as a local process, idempotent create, auth enforced
- [x] check  - [ ] review  **S7** Runner containerised at `.10`, driven from inside the cluster

## Stage C - Control plane, fake provisioner

- [x] check  - [ ] review  **S8** CRD + claim creation, ownerRef → Namespace, finalizer
- [ ] check  - [ ] review  **S9** Resync computes `referencedBy`
- [ ] check  - [ ] review  **S10** Soft delete: orphan, expiry, resurrection
- [ ] check  - [ ] review  **S11** Hard delete: namespace destroys immediately
- [ ] check  - [ ] review  **S12** Controller restart still detects the orphan  ← the one most designs skip

## Stage D - Join the planes

- [ ] check  - [ ] review  **S13** IPAM: a block of 10 per namespace
- [ ] check  - [ ] review  **S14** Real provisioning via the runner; Secret + Service + EndpointSlice

## Stage E - The app

- [ ] check  - [ ] review  **S15** Voting app migrated; no PVC or StatefulSet; both kustomize overlays build
- [ ] check  - [ ] review  **S16** Six R-checks reworked (R2, R8, R9, R10, R11, R16, R17); `make verify` = 17 PASS
- [ ] check  - [ ] review  **S17** Two namespaces, `make jit-verify` J1-J11 pass, Makefile targets added

## Notes carried from the app's own docs

- Checkpoint scripts use `set -euo pipefail` and **must** exit non-zero. `verify.sh`
  deliberately omits `-e` and returns 0 even when checks fail (SCRIPTS-GUIDE §12) -
  parse `.workflow/verify.md` for the count, never trust its exit code.
- Scripts live in `app/scripts/`, driven by the root `Makefile`.
- Database name is `voting`. `votingdb` was the never-populated placeholder.
- Avoid host port 5000 (AirPlay).

## Review

*(fill in after S16: what changed from the design, and why)*

## Lessons

*(anything reworked goes in `lessons.md` as a rule that prevents the repeat)*
