# JIT Infra PoC - Tracker

Design: [jit-infra-poc.md](./jit-infra-poc.md)
Steps: [build-plan.md](./build-plan.md)
Reviews: [reviews/](./reviews/)

Each step has **two** boxes. Tick `check` when the checkpoint printed `PASS`; tick
`review` when a different model wrote `CLEAR` in `docs/reviews/SNN-findings.md`.

A step with one box ticked is not done. One step per session.

This file is a tracker, not a record. Keep it to boxes and links: run logs live in
`docs/evidence/`, a step's outcome in `docs/reviews/SNN-findings.md`, the rules a rework
produced in `docs/lessons.md`, and the state of play in `memory-bank/`.

## Decisions (settled)

- [x] Annotation on the **Deployment** - tenants cannot edit namespaces
- [x] Claim owned by the **Namespace** - survives Deployment churn; one ns per app
- [x] **Two-speed cleanup** - Deployment delete starts a TTL; Namespace delete destroys now
- [x] Redis, Postgres and pgAdmin all on the annotation path; no manual tier
- [x] No snapshot guardrail in the PoC - soft delete covers the accident that matters
- [x] All work in `k8s-just-in-time-infra/`; the voting app is copied into `app/`, never edited in place
- [x] **Tenants never run in `default`** - the demo lives in `voting-a`/`voting-b`, and `default` holds the
      control plane (the controller and its `jit-ipam` ledger). `app/Makefile` defaults `NS` and
      `KUSTOMIZE_DIR` to the `voting-a` overlay, so a bare `make all` cannot land elsewhere.
      *(docs/evidence/s17-cold-path-order.log)*
- [x] **A container removal takes its volume** - `tofu destroy` always did it; `jit-down`'s by-name sweep
      now does too. A Postgres data directory carries its own password, so a volume outliving its container
      makes the next stack's fresh password unusable. *(docs/evidence/s17-cold-path-green.log)*
- [x] **The console owns no behaviour** - every action it can take is a single make target from
      `make targets`, and everything it displays comes from `make state`, which reads the same
      sources the frozen checks do. A page that computes its own phase or expiry would disagree
      with `make jit-verify` eventually, and the disagreement would be the thing you debug.
- [x] **The timeline is a read model, not a controller change** - every timestamp it needs already
      exists: object `creationTimestamp`s, `docker inspect`, the runner's access log, and the
      controller's own `--timestamps` log, which is the only record of when a claim became Ready
      (no phase transition is timestamped and the claims carry no conditions).
- [x] **The timeline is a target of its own, not a key in `make state`** - it reads a log and
      inspects containers, and `make state` is polled every two seconds. Putting it in that
      document would make the console's own poll the expensive part of the demo.

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

- [x] check  - [x] review  **S8** CRD + claim creation, ownerRef → Namespace, finalizer
- [x] check  - [x] review  **S9** Resync computes `referencedBy`
- [x] check  - [x] review  **S10** Soft delete: orphan, expiry, resurrection
- [x] check  - [x] review  **S11** Hard delete: namespace destroys immediately
- [x] check  - [x] review  **S12** Controller restart still detects the orphan  ← the one most designs skip

## Stage D - Join the planes

- [x] check  - [x] review  **S13** IPAM: a block of 10 per namespace
- [x] check  - [x] review  **S14** Real provisioning via the runner; Secret + Service + EndpointSlice

## Stage E - The app

- [x] check  - [x] review  **S15** Voting app migrated; no PVC or StatefulSet; both kustomize overlays build
- [x] check  - [x] review  **S16** Six R-checks reworked (R2, R8, R9, R10, R11, R16, R17); `make verify` = 17 PASS
- [x] check  - [x] review  **S17** Two namespaces, `make jit-verify` J1-J11 pass, Makefile targets added

## Stage F - The console

- [x] check  - [x] review  **S18** Every console action is one make target; `make state` is the read model

## Stage G - The console, checkpointed

The page and the proxy were built outside the plan, so S19 and S20 are retro-checkpoints:
written from `build-plan.md`'s Goal, then run against the code as it stands.

- [x] check  - [ ] review  **S19** The page reads `make state` and the proxy, and offers no button the allowlist cannot run
- [ ] check  - [ ] review  **S20** The proxy runs the allowlist, never a shell, one run at a time
- [ ] check  - [ ] review  **S21** `make timeline`: every event with a time and a source  ← needs S18's array amended to 14 names (`claim`, `timeline`), one approval

## Notes carried from the app's own docs

- Checkpoint scripts use `set -euo pipefail` and **must** exit non-zero. `verify.sh`
  deliberately omits `-e` and returns 0 even when checks fail (SCRIPTS-GUIDE §12) -
  parse `.workflow/verify.md` for the count, never trust its exit code.
- Scripts live in `app/scripts/`, driven by the root `Makefile`.
- Database name is `voting`. `votingdb` was the never-populated placeholder.
- Avoid host port 5000 (AirPlay).

## Review

What changed from the design, and why. The verdicts are in `docs/reviews/`; the
failure-by-failure detail is in `docs/lessons.md`.

- **S15 - the migration.** Postgres and Redis left `app/kustomize/` for the JIT containers: no PVC, no
  StatefulSet, and pgAdmin's host port per claim. The design's two-speed cleanup is implemented as the
  infra *running* through the retention window rather than stopped - a production answer, noted not built.
- **S16 - the R-checks.** Reworking the six checks the plan named also invalidated R3, R4, R6 and R7,
  which read the containers through the shared `psql_q` / `redis_q` helpers. The helpers and R7 changed;
  the four assertions did not.
- **S17 - the demo and the J-suite.** The design specified no serialisation for the IPAM address pick, and
  two claims could take the same address - fixed with a per-namespace lock around read-pick-patch. J11 had
  to be repaired before it could assert anything (prefix encoding, and a missing `pass` line). `voting-b`
  patches the shared base rather than the base being parameterised, because two namespaces cannot share an
  Ingress host or a pgAdmin host port.

## Lessons

Rules that prevent a repeat live in [lessons.md](./lessons.md) - from S15, S16, the S16
review and S17. Anything reworked belongs there, not here.
