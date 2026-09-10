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
- [x] check  - [ ] review  **S16** Six R-checks reworked (R2, R8, R9, R10, R11, R16, R17); `make verify` = 17 PASS
  - `bash scripts/checks/S16.sh` → exit 0 on three consecutive runs (/tmp/s16-run1-keep.log,
    /tmp/s16-run2.log, /tmp/s16-run3.log): `PASS: ===== 17 PASS, 0 FAIL =====`,
    `PASS: no StatefulSet and no PVC in default`.
  - Deploying the migrated app into `default` made `scripts/checks/S00.sh` fail honestly
    (`FAIL: voting-app-redis not ready`, exit 1) — see the flags below.
- [ ] check  - [ ] review  **S17** Two namespaces, `make jit-verify` J1-J11 pass, Makefile targets added

## Notes carried from the app's own docs

- Checkpoint scripts use `set -euo pipefail` and **must** exit non-zero. `verify.sh`
  deliberately omits `-e` and returns 0 even when checks fail (SCRIPTS-GUIDE §12) -
  parse `.workflow/verify.md` for the count, never trust its exit code.
- Scripts live in `app/scripts/`, driven by the root `Makefile`.
- Database name is `voting`. `votingdb` was the never-populated placeholder.
- Avoid host port 5000 (AirPlay).

## Flags carried forward (verdicts from reviews)

- **S17:** pgAdmin publishes a fixed host port (`http_port`, default 5050), so `voting-a`
  and `voting-b` cannot both run it — the second claim goes `Failed`. Parameterise
  `http_port` per claim via annotation params, or run pgAdmin in one namespace.
  *(S15 findings item 10)*
- **S17:** the controller writes the JIT Service port as `int(outputs.get("port", "6379"))`.
  The pgadmin module exposes no `port` output and listens on 80, so `jit-pgadmin`
  advertises 6379 (redis's default). No R-check touches pgAdmin, so nothing notices.
  *(found in S16)*
- **S17:** `scripts/checks/S00.sh` now fails honestly — `FAIL: voting-app-redis not ready
  (ready='' desired='')`, exit 1 — because `default` runs the migrated app. That is the
  stale assertion from S15 surfacing, not a regression; its header documents it and
  re-opening a frozen gate was rejected in S15 findings item 9. Decide in S17 whether to
  re-open or retire it.
- **Deferred (runner):** move the runner to `tofu output -json` so a module can own a
  sensitive output. Until then the controller writes the postgres password itself.

## Review

**S16 — what changed from the design, and why.**

- The build plan named six rows (R2, R8, R9, R10, R11, R16, R17); the migration also
  invalidated R3, R4, R6 and R7, which read Postgres/Redis through the shared `psql_q` /
  `redis_q` helpers — and R7 called `kubectl exec "$PGPOD"` directly. The helpers and R7
  changed; the four bodies did not, so their assertions are unaltered.
- R9's post-restart wait no longer names a pod: it polls `pg_isready` inside the container
  and then waits for the `result` Deployment to be Ready. SCRIPTS-GUIDE §9 named the
  hardcoded `voting-app-postgres-0` as the reason `CLUSTER` was not fully overridable.
- R10/R11 are namespace-scoped (`kubectl get deploy -n "$NS"`) as well as counted at 3:
  the JIT controller's own Deployment also runs in `default`, so a cluster-wide count
  would be wrong regardless of the 5→3 change.
- R17 reads the `jit-postgres` outputs Secret instead of the app's own (now deleted)
  `voting-app-postgres` Secret.
- `app/docs/MANUAL-TESTING-GUIDE.md` was updated where it mirrored the reworked checks — a
  guide whose copy-paste commands name a deleted pod is worse than no guide.

## Lessons

Rules that prevent a repeat live in [lessons.md](./lessons.md). The first entries come
from S15: the kustomize overlay cycle, secrets routed through module outputs,
pending-versus-Failed on a dependency that is not ready, and the carried-forward pgAdmin
port and committed-SECRET_KEY notes.
