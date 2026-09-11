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
- [x] check  - [x] review  **S16** Six R-checks reworked (R2, R8, R9, R10, R11, R16, R17); `make verify` = 17 PASS
  - `bash scripts/checks/S16.sh` → exit 0 on three consecutive runs (docs/evidence/s16-run1-keep.log,
    docs/evidence/s16-run2.log, docs/evidence/s16-run3.log): `PASS: ===== 17 PASS, 0 FAIL =====`,
    `PASS: no StatefulSet and no PVC in default`.
  - Deploying the migrated app into `default` made `scripts/checks/S00.sh` fail honestly
    (`FAIL: voting-app-redis not ready`, exit 1) — see the flags below.
  - After the review's CONCERNS (no blockers): the helper reads are guarded so two failed
    reads cannot agree, and R8's worker restore runs on every path. Re-run after the fix
    → exit 0, 17 PASS (`docs/evidence/s16-postfix2.log`); negative test `docs/evidence/s16-negative2.log`.
- [x] check  - [ ] review  **S17** Two namespaces, `make jit-verify` J1-J11 pass, Makefile targets added
  - `bash scripts/checks/S17.sh` → exit 0, ending `PASS: J1-J11 all PASS in .workflow/verify-jit.md`,
    `PASS: ===== 17 PASS, 0 FAIL ===== in voting-a`, `PASS: S17 - two namespaces, J1-J11 and the
    R-checks both green`. Full run: `docs/evidence/s17-run.log` (copy `docs/evidence/s17-green-run.log`), suite
    report `docs/evidence/verify-jit-green.md`.
  - J1 is no longer flaky. `docs/evidence/race-test.sh` — three clean-slate `voting-a` deploys, each
    requiring three distinct IPs **and** `count: 3` in the IPAM ledger — is **3/3 OK**
    (`docs/evidence/race-test.log`). The fix is `namespace_lock(ns)` over the read-pick-patch in
    `ensure_claim`, plus releasing a claim's block once (`handle_claim_delete` skips phase
    `Deleting`).
  - Two earlier full runs failed at J11 and are kept, because they are what found it:
    `docs/evidence/s17-run-j11fail.log` (403 SignatureDoesNotMatch — the prefix was signed as `ns/` rather
    than `ns%2F`) and `docs/evidence/s17-run-j11-nopass.log` (J11 passed but printed nothing, so a gate
    requiring `^J11 PASS` could not see it).
  - `make check STEP=NN` routing is asserted in the same script. The S16 gate needs `NS=voting-a`.
  - **Post-fix re-run.** After the two fixes below: `bash scripts/checks/S17.sh` → exit 0 again,
    `PASS: J1-J11 all PASS in .workflow/verify-jit.md`, `PASS: ===== 17 PASS, 0 FAIL ===== in
    voting-a`, `PASS: S17 - two namespaces, J1-J11 and the R-checks both green`
    (`docs/evidence/s17-run-postfix.log`, suite report `docs/evidence/verify-jit-postfix.md`).
  - **The resync retry path leaked an IP block.** The TTL path released a swept claim's block in one
    place, only when its *own* destroy succeeded; the retry branch destroyed, cleaned up and deleted
    the claim while releasing nothing; and `handle_claim_delete` deliberately skips phase `Deleting`.
    So a sweep that failed at the expiry — the runner being down, which is what J10 rehearses — and a
    retry that then succeeded left the block allocated for good, claim and container both gone. One
    of the ten blocks, lost silently, per occurrence. Proved by executing it:
    `docs/evidence/leak-probe2.sh` / `leak-probe2.log` (claim gone, container gone, ledger still
    counting the namespace). Fixed in `jit-controller/main.py`: both teardown paths release, and each
    releases only once `remove_finalizer_and_delete` reports the claim is gone, so the release and the
    claim's removal move together and exactly one path releases. Re-proved by
    `docs/evidence/leak-probe3.sh` / `leak-probe3.log` (`LEDGER AFTER` names voting-a only) with the
    controller log in `docs/evidence/leak-probe3-controller.log` showing the retry branch releasing
    before the delete handler skips.
  - **The README's escape hatch named the wrong variables.** Step 2 of §"If it goes wrong" documented
    `-var postgres_password` and `-var http_port` for pgadmin but not `postgres_url`, which
    `jit-modules/modules/pgadmin/variables.tf` requires with no default: the documented manual destroy
    failed with `No value for required variable: postgres_url`. Step 2 now states what each module
    requires and where each value comes from.

## Notes carried from the app's own docs

- Checkpoint scripts use `set -euo pipefail` and **must** exit non-zero. `verify.sh`
  deliberately omits `-e` and returns 0 even when checks fail (SCRIPTS-GUIDE §12) -
  parse `.workflow/verify.md` for the count, never trust its exit code.
- Scripts live in `app/scripts/`, driven by the root `Makefile`.
- Database name is `voting`. `votingdb` was the never-populated placeholder.
- Avoid host port 5000 (AirPlay).

## Flags carried forward (verdicts from reviews)

All five S17 verdicts below are **resolved in S17**, each with the assertion that proves it.

- **pgAdmin's host port is per claim.** RESOLVED: the pgadmin module takes `http_port`, the
  claim's annotation carries `params.http_port`, and `app/kustomize/overlays/voting-b` sets it
  to 5051 — both namespaces run pgAdmin, and J8 reads voting-b's Service back. *(S15 findings
  item 10)*
- **A module output that does not exist cannot be defaulted away.** RESOLVED: the pgadmin module
  exports `port = 80`, and `create_jit_service` re-states the spec on 409 so a Service created
  before the fix does not keep the stale 6379. J3 asserts port 80 in voting-a. *(found in S16)*
- **`verify.sh`'s remaining `default`-shaped reads.** RESOLVED: R14 and R15 are namespace-scoped
  (`kubectl get svc -n "$NS"`, `kubectl get pods -n "$NS"`). `RELEASE`, `VOTE_URL` and
  `RESULT_URL` stay env-overridable, which is what lets `make verify NS=voting-a` drive the demo
  namespace. *(S16 findings item 8)*
- **The app's docs described the pre-migration topology.** RESOLVED: `app/README.md` carries a
  pre-migration banner, and `app/docs/SCRIPTS-GUIDE.md` describes the container-based tiers, the
  named volume and pgAdmin's overridable host port. *(S16 findings item 9)*
- **`verify-jit.sh` must not reuse the silent-empty helper pattern.** RESOLVED: it runs
  `set -euo pipefail`, and every read a comparison depends on is guarded and names the container
  it failed to read. *(S16 review concern 1)*
- **S17 decision — `scripts/checks/S00.sh` keeps failing, deliberately.** It fails honestly
  (`FAIL: voting-app-redis not ready`, exit 1) because `default` now runs the migrated app while
  S00's assertions are pre-migration. It was not re-opened (rejected in S15 findings item 9) and
  not retired: a frozen gate that documents its own staleness is a record, not a defect. Carried
  past S17 unchanged — no S17 checkpoint runs it.
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

**S17 — what changed from the design, and why.** (checkpoint PASS; review pending)

- **The IPAM design had no serialisation, and needed one.** S13 specifies "a block of 10 per
  namespace" and `allocate_block` counts claims; nothing said the address pick inside a block had
  to be atomic, and J1 intermittently handed two claims the same address. Fixed with
  `namespace_lock(ns)` around read-pick-patch and by releasing a swept claim's block exactly once.
  The design's guarantee is unchanged; only the mechanism that upholds it.
- **J11 had to be repaired before it could be asserted at all.** Its prefix was signed as `ns/`
  rather than `ns%2F` (MinIO answered 403), and it had no `pass` line, so a *passing* J11 printed
  nothing. Neither the design note nor the build plan says how to read the state bucket; the check
  is this step's implementation of "one state object per namespace-module, under distinct
  prefixes".
- **`voting-b` patches the shared base rather than the base being parameterised.** Two namespaces
  cannot share one Ingress host or one pgAdmin host port, so the second namespace patches both.
  The plan's "deploy voting-a and voting-b from the same base" still holds; parameterising the
  base instead would have moved voting-a off the app's documented defaults.
- **Retention keeps the infra *running*, not stopped.** The design's "two-speed cleanup" is
  implemented as the containers continuing until the TTL expires. Stopping them is listed in the
  build plan's "Done" section as something production needs and this PoC omits.

## Lessons

Rules that prevent a repeat live in [lessons.md](./lessons.md). The first entries come
from S15: the kustomize overlay cycle, secrets routed through module outputs,
pending-versus-Failed on a dependency that is not ready, and the carried-forward pgAdmin
port and committed-SECRET_KEY notes.
