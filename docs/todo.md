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
- [x] **Tenants never run in `default`** - the demo app lives in `voting-a`/`voting-b`, and `default` holds
      the control plane (the controller and its `jit-ipam` ledger). Settled by S17's review: the base
      kustomization carries no namespace, so a bare `make all` used to land the app in `default`, where its
      Ingress fought `voting-a` for `vote.localhost` - and the J-suite's PREREQ then refused to run at all
      (`docs/evidence/s17-cold-path-order.log`). `app/Makefile` now defaults `NS`/`KUSTOMIZE_DIR` to the
      `voting-a` overlay so the bare command cannot do it again.

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
  - **Review (a different model, a fresh task): CONCERNS, no blockers** — `docs/reviews/S17-findings.md`,
    with its own live checkpoint run at c95c051 (11 PASS, then 17 PASS). All five concerns and what each
    became:
    1. `jit-down` left the IPAM ledger behind → **fixed**: `scripts/jit-down.sh` deletes `jit-ipam`
       after the claims have been destroyed, so the ledger it leaves is the truthful one. Verified by
       running the whole bounce — the ConfigMap is gone after `jit-down`, and comes back as
       `{"voting-a": {"offset": 0, "count": 3}}` once the claims are re-created.
    2. The escape hatch did not mention the ledger → **fixed**: README step 3 gives the one-liner that
       drops the namespace's entry and names `make jit-down` as the blunt version.
    3. `var.share_dir`'s `/tmp` default silently reproduces the original pgadmin bug for standalone use
       → **documented where it bites**: the escape hatch now says to run tofu on the host and pass
       `-var share_dir="$HOME/.jit-host-share"`, where `deploy/runner.sh` writes the file. Requiring
       the variable is the production answer and would break the escape hatch as written, so it is
       recorded as a flag, not taken.
    4. The build-plan Done item "a cold `make destroy`" was never exercised → **closed**, and it was
       the right concern: the cold path hid four defects (see the cold-start record below). The reason
       found by reading it was real — `make destroy` deletes the k3d cluster, which takes
       `jit-controller:latest` with it, while `scripts/jit-up.sh` assumed the image was already
       imported — and is fixed. Green run: `docs/evidence/s17-cold-path-green.log`.
    5. Tenant visibility of an `Orphaned` claim → **open by design**: the design note lists it under
       what production needs, and the platform operator's `kubectl get infraclaims` stays the only
       view. S17 changed nothing here.
  - Running the bounce found something the review did not: **`make jit-up` does not bring a tenant
    back.** kopf does not replay create for Deployments that already existed, and an unchanged
    `kubectl apply` is a no-op, so after `jit-down` + `jit-up` the claims have to be re-triggered by
    touching the annotated Deployment (`kubectl rollout restart deploy/<name> -n <ns>`). Documented in
    `scripts/jit-down.sh` and the README's step 4; verified by running it (three claims Ready and the
    ledger rebuilt from empty).
  - **The bounce's second run failed, and that failure found a defect of its own.** `jit-down` deleted
    the claims with `--wait=false` and then removed the runner, so the deletes were still in flight:
    they sat Terminating for the whole two-minute window (`must be 0): 3`), came back *Ready* with no
    container behind them, and — because Ready is what the controller checks before provisioning —
    blocked the tenant's recovery (`containers up: 0 of 3`, R2 FAIL). That log is kept, because the
    green run alone would not have proved it: `docs/evidence/s17-jitdown-bounce-race.log`.
    `scripts/jit-down.sh` now waits for the claims to actually go before the runner does, and warns
    loudly if they will not. Re-run end to end: `docs/evidence/s17-jitdown-bounce.log` — ledger absent
    after `jit-down`, nothing left over after `jit-up`, and `17 PASS, 0 FAIL` once the tenant is
    touched.
  - **That failing run also exposed an unguarded read in the R-checks.** With R1 unable to parse the
    vote page, `OPTS` is empty, every later `${OPTS[0]}` aborts with `unbound variable` under `set -u`,
    and — worse than noise — `grep -q "${OPTS[0]}"` on an empty name matches any line, so R5's two
    label assertions could pass vacuously on a dead app. `app/scripts/verify.sh` pads `OPTS` to two
    slots and R5 now requires them non-empty. Negative test:
    `docs/evidence/s17-rchecks-negative-options.log` (`10 PASS, 7 FAIL`, no shell noise, R5 fails
    honestly); the normal run is unchanged at `17 PASS, 0 FAIL`.

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
  sensitive output. Until then the controller writes the postgres password itself. Unchanged by the
  cold-start fix: what moved there was the volume, not the password.
- **Cold start — closed, and the runs earned their keep.** S17's review concern 4. The path hid four
  defects, in the order it hits them. `s17-cold-path-gaps.log` — the cluster's containerd went with the
  cluster, so `jit-controller:latest` went with it and `make jit-up` then waited 180s to fail on
  ImagePullBackOff; the module containers live on the Docker daemon, outside the cluster, and survive both
  the app and the cluster, holding the addresses the next stack's empty ledger is about to hand out;
  `app/scripts/deploy.sh` creates the cluster and then stops until the CRD exists while `scripts/jit-up.sh`
  needs the cluster, so the cluster is created by a `deploy` that stops by design; and a bare `make all`
  deploys into `default`, whose Ingress claims `vote.localhost` — the host the `voting-a` demo owns — so
  `make jit-verify` refuses to run ("one namespace per demo host"). Fixed: `jit-up.sh` imports the
  controller image when the cluster lacks it, `jit-down` no longer dies on a cluster with no CRD (its own
  `set -euo pipefail` bug, found by this run), and a bare `make all` no longer lands the app in `default`
  (`app/Makefile` defaults `NS`/`KUSTOMIZE_DIR` to the `voting-a` overlay — see the decision in
  "Decisions (settled)").
  - **The fourth, and the last blocker: settled, not patched.** `s17-cold-path.log` reached provisioning —
    three claims Ready, vote rolled out — and stopped at `init-db` with `FATAL: password authentication
    failed for user "postgres"`, because the postgres data volume outlived the container sweep while the
    controller wrote a fresh password for the new stack. The code had already answered the question that
    raised: a container removal takes its volume — `tofu destroy` destroys the `docker_volume` with the
    container, every recorded J6 run reports `postgres data volume removed`, and
    `jit-modules/modules/postgres/main.tf` forbids the `random_password` alternative. What broke the rule
    was `jit-down`'s fallback sweep, which removes containers *by name* precisely when the destroy cannot
    run: no CRD, no state, no Secret — the state that made the run cold. It now removes `<container>-data`
    with the container (`scripts/jit-down.sh` step 2). Persisting the password instead would not have
    rescued the volume that already existed either: its password lives inside the data directory and nowhere
    else, so a volume reset was needed whichever way this went. Reasoning in `docs/lessons.md`.
  - **The build plan's last Done item is now run, and green.** `docs/evidence/s17-cold-path-green.log`
    (phase `full`): step 3 shows `jit-volumes=[voting-a-postgres-postgres-data ]` → `jit-volumes=[]`, and the
    run ends cold and green — `make all` = `17 PASS, 0 FAIL`, `make jit-verify` = `11 PASS, 0 FAIL`, three
    claims Ready, and the ledger rebuilt as `{"voting-a": {"offset": 0, "count": 3}}`. The gate re-run on
    the final code, `bash scripts/checks/S17.sh`, ends on its last PASS line
    (`docs/evidence/s17-final-gate.log`), which under `set -euo pipefail` is reachable only on success.
- **`var.share_dir` keeps a `/tmp` default, deliberately.** S17 review concern 3. The default is only
  correct when tofu runs on the Docker daemon's host; the pgadmin module is silently wrong without it
  (Docker creates an empty directory instead of mounting `servers.json`). Requiring the variable is the
  production answer, but it would force the escape hatch in the README to pass it as well, so S17 chose
  a documented default plus a note in the escape hatch. Revisit before any real deployment.

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
