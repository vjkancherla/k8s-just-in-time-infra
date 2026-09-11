# JIT Infra PoC - Build Plan

Design: [design/jit-infra-poc.md](design/jit-infra-poc.md)
Tracker: [todo.md](./todo.md)
Rules: [../.clinerules/01-jit-poc.md](../.clinerules/01-jit-poc.md)

18 steps plus S-1. Each one is small enough to finish in a single session and ends in a
checkpoint that either prints `PASS` or stops the work.

## How to use this document

Do **one step**. Read only the files that step lists. Run its checkpoint. Paste the
real output.

A step is done when **two** gates pass:

1. The checkpoint prints `PASS`.
2. A **different model** reviews the diff and writes `CLEAR` in
   `docs/reviews/SNN-findings.md`.

Both boxes in `todo.md`, or the step is not done.

## Step completion protocol

1. Checkpoint passes.
2. Commit. One step, one commit.
3. Emit `docs/reviews/SNN-review-prompt.md` from
   `docs/reviews/REVIEW-PROMPT-TEMPLATE.md`. Fill **only** step number, the goal copied
   verbatim from this document, and the commit range. Add nothing else - a summary of
   your own work anchors the reviewer on your framing instead of the design.
4. **Stop and print:**

   > S<NN> checkpoint passed, committed as `<sha>`.
   > Switch to a different model, start a fresh task, paste
   > `docs/reviews/S<NN>-review-prompt.md`.
   > I will not start S<NN+1> until `S<NN>-findings.md` says CLEAR.

5. Do not begin the next step. Do not offer to.

On `BLOCKED`: reopen the step, fix, re-run the checkpoint, re-review. The tracker box
stays unticked throughout. If you disagree with a blocker, that goes to the human as a
design question - do not argue it with the reviewer.

**Which model reviews:** any model other than the implementer. For S10, S14 and S15 -
the state machine, the integration, and the migration - use the strongest model you have,
including a cloud one. Those are the steps where a missed error is expensive to unwind.

A checkpoint is not a description of success. It is a command that exits 0.

Each checkpoint lives at `scripts/checks/SNN.sh`. **All of them are written in step S-1,
before any implementation**, from the assertions below. Not during the step they gate -
an agent that authors the assertion it is trying to satisfy will make the two agree.

They follow this shape:

```bash
#!/usr/bin/env bash
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }
# ... assertions ...
echo "PASS"
```

**Do not copy `app/scripts/verify.sh`'s error handling.** It uses `set -uo pipefail`
deliberately - without `-e` - so that one failing requirement does not abort the other
sixteen. A documented consequence is that **a failing check still exits 0**. That is
right for a report and wrong for a gate. Checkpoint scripts use `set -euo pipefail` and
must exit non-zero on failure, or the whole build plan is decorative.

## Unit tests

Checkpoints are the evidence. Unit tests are the agent's diagnostic tooling - they turn
"S10 failed" into "the expiry comparison is off by a sign". Both are useful; only the
first is proof.

Write unit tests for the four pieces of pure, fiddly logic:

- expiry arithmetic (`now > expiresAt`, TTL parsing)
- `referencedBy` computation from a Deployment list
- IP allocation and release from the `jit-ipam` block
- annotation JSON parsing and validation

Do **not** write them for glue - the controller's API calls, the runner's HTTP handlers.
A checkpoint covers those better and a unit test there is mocking your own code back at
yourself.

## Workspace layout

```
<workspace>/
  local-ai-dev-workflow-voting-app/   READ ONLY reference
  jit-infra-poc/                      all work happens here
    .clinerules/
    docs/design/
    docs/
    app/                              copy of the voting app, edited freely
    jit-modules/                      terraform modules
    jit-runner/                       out-of-cluster provisioning service
    jit-controller/                   in-cluster operator
    deploy/                           cluster + minio + runner bootstrap
    scripts/checks/                   one checkpoint script per step
```

---

## Stage Z - Before anything

### S-1. Write every checkpoint script

**Goal:** all 18 checkpoints exist and all of them fail.

**Read:** this document. Nothing else.

**Do:** turn each step's assertions into `scripts/checks/SNN.sh`. `set -euo pipefail`,
`fail()` helper, exit non-zero. Nothing is implemented yet, so every one will fail -
that is the point, and it proves each asserts something real.

Also write:
- `scripts/checks/run-all.sh` - runs them in order, reports which pass
- `scripts/review-guard.sh <commit-range>` - mechanical pre-review check. Fails if the
  range touches `scripts/checks/`, `.clinerules/`, CI config, or adds a dependency.
  Deterministic, so the reviewing model does not have to be trusted to spot it.

**Checkpoint:** `run-all.sh` executes all 18 and reports 18 failures with readable
messages, zero syntax errors. `review-guard.sh` exits non-zero on a commit that touches
`scripts/checks/`.

**Gate:** these files are frozen. Do not edit a checkpoint again. If one turns out to be
wrong, stop and raise it as a design question - do not adjust it to match the code.

---

## Stage A - Baseline

### S0. Copy the app and rebuild the cluster with a fixed subnet

**Goal:** the unmodified voting app runs on a cluster that has the subnet the rest of
this work needs. Nothing is JIT yet.

**Read:** `local-ai-dev-workflow-voting-app/README.md`, `docs/SCRIPTS-GUIDE.md`,
`docs/MAKEFILE-GUIDE.md`, `scripts/deploy.sh`, `Makefile`.

**Do:**
- `cp -R` the voting app repo into `jit-infra-poc/app/`. Drop `.git` and the stale
  `scripts/verify.sh.bak` (SCRIPTS-GUIDE §12 says it is dead).
- Tear down the existing cluster: `cd app && make destroy`.
- In `app/scripts/deploy.sh`, add `--subnet 172.19.0.0/16` to the
  `k3d cluster create` line. Change nothing else.
- `cd app && make all` (deploy then verify).

**Checkpoint** `scripts/checks/S00.sh`:
- `docker network inspect k3d-voting-app` shows subnet `172.19.0.0/16`
- all 5 workloads Ready
- `.workflow/verify.md` shows `17 PASS, 0 FAIL`
- assert the count by parsing that file - **do not** rely on `verify.sh`'s exit code,
  which is 0 even when checks fail

**Gate:** if the app does not work here, nothing later will. Do not proceed.

---

### S1. Prove a pod can reach a container by Docker-network IP

**Goal:** confirm the single assumption the whole design rests on.

**Read:** design note, "Networking".

**Do:**
- `docker run -d --name probe-redis --network k3d-voting-app --ip 172.19.0.100 redis:7-alpine`
- From inside the cluster: `kubectl run probe --rm -it --restart=Never --image=redis:7-alpine -- redis-cli -h 172.19.0.100 ping`

**Checkpoint** `scripts/checks/S01.sh`: the above prints `PONG`.

**Gate:** **This is the design's one hard gate.** If it fails, stop and report. Do not
work around it. The fallback (host port + `host.k3d.internal`) changes IPAM into port
allocation and needs a design amendment first.

Clean up `probe-redis` afterwards.

---

## Stage B - Provisioning plane, no Kubernetes

Everything in this stage is testable from a shell. The cluster is not involved.

### S2. MinIO as the Terraform state backend

**Goal:** somewhere for state to live.

**Do:**
- `deploy/minio.sh`: run MinIO at `172.19.0.11` on the k3d network, published console
  port, fixed root credentials in `deploy/.env` (gitignored).
- Create bucket `jit-state`.
- Keep the console off port 5000 - AirPlay claims it on macOS, which is why the repo
  has a `REGISTRY_PORT` escape hatch. MinIO's 9000/9001 are fine.

**Checkpoint** `scripts/checks/S02.sh`: `mc ls` (or an `aws s3 ls --endpoint-url`)
lists `jit-state`.

---

### S3. `modules/redis`

**Goal:** one Terraform module that creates a Redis container at a caller-supplied IP,
with state in MinIO.

**Read:** design note, "Components".

**Do:**
- `jit-modules/modules/redis/` using the `kreuzwerker/docker` provider.
- Variables: `name`, `ip`, `network`, `maxmemory`.
- Outputs: `address`, `port`, `url`.
- Backend config passed at `init` time, key `ns/<namespace>/redis/terraform.tfstate`.

**Do by hand:** `tofu init` with a test key, `tofu apply`, then `tofu destroy`.

**Checkpoint** `scripts/checks/S03.sh`:
- after apply: container exists at the requested IP, `redis-cli ping` from a pod returns `PONG`
- state object exists in MinIO under the expected key
- after destroy: container gone, and a second `destroy` is a clean no-op

---

### S4. `modules/postgres`

**Goal:** same, plus a named volume that outlives the container.

**Do:** variables `name`, `ip`, `network`, `db`, `user`, `password`. Named Docker
volume. Outputs `address`, `port`.

**Checkpoint** `scripts/checks/S04.sh`:
- apply, create a table, insert a row
- `docker rm -f` the container, re-apply
- **the row is still there**
- destroy removes container *and* volume

---

### S5. `modules/pgadmin`

**Goal:** a browser-reachable pgAdmin pointed at the S4 Postgres.

**Do:** container at a static IP with a published host port. Pre-register the Postgres
server via a servers.json.

**Checkpoint** `scripts/checks/S05.sh`: HTTP 200 on the published port, and the
container can `pg_isready` against the Postgres IP.

---

### S6. `jit-runner` as a local process

**Goal:** the API that turns an HTTP call into a `tofu` run. Not containerised yet.

**Read:** design note, "Components", "Failure modes".

**Do:**
- `jit-runner/`: FastAPI. `POST /v1/runs` `{module, version, workspace, params}` →
  `{status, outputs}`. `DELETE /v1/runs/{workspace}`. Bearer token from env.
- Fetch the module from `jit-modules` at a git ref into a temp dir per run.
- `tofu init` with backend key derived from `workspace`, then `apply` / `destroy`.
- Return non-2xx with the tofu stderr on failure.

**Checkpoint** `scripts/checks/S06.sh`:
- `curl` create → 200, outputs contain the redis URL, container exists
- `curl` the same create again → 200, still one container (idempotent)
- `curl` destroy → container gone
- `curl` with a bad token → 401

---

### S7. Containerise the runner at `172.19.0.10`

**Goal:** the runner is reachable from inside the cluster.

**Do:** Dockerfile with `tofu` (check the **arm64** release), Docker socket mounted,
run on the k3d network at `.10`. `deploy/runner.sh`.

**Checkpoint** `scripts/checks/S07.sh`:
- `kubectl run` a curl pod, `GET http://172.19.0.10:8080/healthz` → 200
- a create/destroy cycle driven entirely through that pod

**Gate:** Stage B is done. From here the cluster is involved in everything.

---

## Stage C - Control plane, fake provisioner

The controller is built against a **fake** provisioner that writes and deletes a dummy
Secret. No Terraform. A wrong state transition costs nothing here, which is the point -
this is where the genuinely new logic lives.

### S8. CRD and claim creation

**Goal:** an annotation produces a claim owned by the Namespace.

**Read:** design note, "Claim identity and idempotence".

**Do:**
- `InfraClaim` CRD: spec `{module, moduleVersion, params, softDeleteTTL}`, status
  `{phase, referencedBy[], expiresAt, outputsSecret, endpoint, message}`.
- Printer columns: `PHASE`, `EXPIRES`, `REFS`.
- kopf controller. On an annotated Deployment: create claim `<namespace>-<module>`,
  `ownerReference` → Namespace, finalizer `jit.infra/teardown`.
- Fake provisioner: on Ready, write Secret `jit-<module>`; on destroy, delete it.

**Checkpoint** `scripts/checks/S08.sh`:
- annotate a Deployment → claim exists, phase `Ready`, ownerRef is the **Namespace**
- Secret exists
- re-apply the Deployment → still exactly one claim

---

### S9. Resync computes `referencedBy`

**Goal:** the controller derives references rather than trusting events.

**Read:** design note, "How the controller knows a Deployment is gone".

**Read also:** `docs/design/jit-infra-flows.md` §5 (resync loop) and §4 (state machine).

**Do:** periodic resync (30s in the PoC). For each claim, list live Deployments in the
namespace that annotate that module. Write the list to `status.referencedBy`. Do not
implement orphaning yet.

**Checkpoint** `scripts/checks/S09.sh`:
- two Deployments annotate `redis` → `referencedBy` has both
- delete one → after a resync, `referencedBy` has one
- **claim is still `Ready`** (last-reference rule not yet triggered)

---

### S10. Soft delete - orphan and expiry

**Goal:** the last reference going away starts a clock.

**Do:**
- `referencedBy` empty → phase `Orphaned`, `expiresAt = now + softDeleteTTL`
- a reference reappears → phase `Ready`, `expiresAt` cleared
- sweep: `Orphaned` and past `expiresAt` → destroy, remove finalizer

Use `softDeleteTTL: 2m` for all tests.

**Checkpoint** `scripts/checks/S10.sh`:
- delete the last referencing Deployment → `Orphaned` with an `expiresAt`, **Secret still present**
- re-apply within the window → `Ready`, expiry cleared, same Secret (not recreated)
- delete again, wait past the TTL → Secret gone, claim gone

---

### S11. Hard delete - namespace

**Goal:** namespace deletion destroys now, regardless of expiry.

**Checkpoint** `scripts/checks/S11.sh`:
- put a claim into `Orphaned` with a long TTL (`30d`)
- `kubectl delete ns` → completes; claim and Secret gone **well before** the expiry
- namespace does not hang in `Terminating`

---

### S12. Controller restart resilience

**Goal:** a delete missed while the controller is down is caught by the resync.

**Checkpoint** `scripts/checks/S12.sh`:
- scale the controller to 0
- delete the last referencing Deployment
- scale back to 1
- within one resync interval the claim is `Orphaned`

**Gate:** Stage C is done when S8-S12 all pass with the fake provisioner. Do not wire
Terraform in before that.

---

## Stage D - Join the planes

### S13. IPAM

**Goal:** deterministic addresses per namespace.

**Do:** `jit-ipam` ConfigMap. Allocate a block of 10 from `172.19.0.100-199` on first
claim in a namespace; release when the last claim goes.

**Checkpoint** `scripts/checks/S13.sh`: two namespaces get non-overlapping blocks;
deleting one frees its block; a re-created namespace gets a block again.

---

### S14. Replace the fake provisioner with the runner

**Goal:** real containers, driven by the controller.

**Do:**
- Controller calls `172.19.0.10:8080` with the bearer token from a Secret.
- On success: write the outputs Secret, plus a **Service with no selector** and an
  **EndpointSlice** at the allocated IP.
- On failure: phase `Failed`, message = runner error. No retry storm.
- Conflicting params between two Deployments: first writer wins, warning condition
  naming both.

**Checkpoint** `scripts/checks/S14.sh`:
- annotate → container exists at the allocated IP, Secret + Service + EndpointSlice exist
- a pod resolves the Service name and reaches Redis
- stop the runner, annotate a new Deployment → claim `Failed` with a readable message,
  pod stays unstarted
- re-run S10's soft-delete sequence end to end, now with real containers

---

## Stage E - The app

### S15. Migrate the voting app onto JIT infra

**Goal:** the app runs with no stateful workload in the cluster.

**Read:** `app/kustomize/`, `app/scripts/deploy.sh`, `docs/SCRIPTS-GUIDE.md` §6 and §12.

**Do:**
- Remove the Redis Deployment and Service from `app/kustomize/`.
- Remove the Postgres StatefulSet, Service and PVC.
- Parameterise the namespace with an overlay per environment. **Keep
  `overlays/registry` working** - R12 asserts the registry image override still builds.
- Annotate `vote` with redis, postgres, pgadmin; `worker` with redis.
- **Credentials:** the Postgres module generates the password and the controller writes
  it into the JIT outputs Secret. `kustomize/postgres-secret.env` and its `openssl`
  generation step in `deploy.sh` go away, along with the `SECRET_KEY` line - move that
  to its own Secret. Consuming pods use `secretKeyRef`, `optional: false`.
- Use database name `voting`, not `votingdb`. SCRIPTS-GUIDE §12 records the mismatch:
  the apps and `verify.sh` both use `voting`; `votingdb` was never populated.

**Checkpoint** `scripts/checks/S15.sh`:
- `kubectl apply` into an empty namespace → three containers appear, app reaches Ready
- vote → result works end to end
- `kubectl kustomize app/kustomize` and the registry overlay both build
- **no PVC and no StatefulSet exist in the namespace**

**Gate:** most error-prone step. If the app breaks here it is the migration, not the
controller - S14 already passed.

---

### S16. Rework the six R-checks that the migration invalidates

**Goal:** `make verify` reports 17 PASS again, testing the same properties against
out-of-cluster infra.

**Read:** `app/scripts/verify.sh`, `docs/MANUAL-TESTING-GUIDE.md`.

Eleven checks are unaffected. These six are not:

*(Corrected after the S16 review, 2026-10-09. The original line read "Eleven checks are
unaffected. These six are not", which was wrong on both numbers: the table below lists
**seven** rows, and the shared `psql_q` / `redis_q` helpers also invalidated R3, R4, R6
and R7 — R7 called `kubectl exec "$PGPOD"` directly. Eleven of seventeen checks were
invalidated in total; six were genuinely unaffected — R1, R5, R12, R13, R14, R15.)*

| Req | Currently | Becomes |
|---|---|---|
| R2 | `kubectl exec` redis pod → `LLEN votes` | `docker exec` the redis container |
| R8 | same, drain assertion | same, via `docker exec` |
| R9 | delete pod `voting-app-postgres-0`, 120s readiness wait | `docker restart` the postgres container, wait `pg_isready`, tally unchanged |
| R10 | liveness + readiness on **5** workloads | on **3** |
| R11 | requests + limits on **5** workloads | on **3** |
| R16 | redis `PONG` and `pg_isready` via `kubectl exec` | via `docker exec` |
| R17 | no literal password in manifests; Secret `voting-app-postgres` holds it | no literal password; the **JIT outputs Secret** holds it |

R9's hardcoded pod name is called out in SCRIPTS-GUIDE §9 as the reason `CLUSTER` is
not fully overridable. Removing it is a small bonus.

The four helper-only checks (R3, R4, R6, R7) change only in how they reach the stateful
tiers: rewriting the two helpers to `docker exec` fixes R3, R4 and R6 without touching
their bodies, and R7 needs the one line that called `kubectl exec "$PGPOD"` directly.
Their assertions themselves must not change. *(Added in the 2026-10-09 correction.)*

**Do not** change R1, R5 or R12-R15. If one of those fails, the migration broke
something real - go back to S15.

**Checkpoint** `scripts/checks/S16.sh`: run `make verify`, parse `.workflow/verify.md`,
assert `17 PASS, 0 FAIL`.

---

### S17. Two namespaces, the JIT suite, and Makefile targets

**Goal:** the demo, and the acceptance tests from the design note.

**Do:**
- Deploy `voting-a` and `voting-b` from the same base.
- `scripts/verify-jit.sh` implementing J1-J11 with `softDeleteTTL: 2m`, writing
  `.workflow/verify-jit.md` - same shape as `verify.sh`, but `set -euo pipefail` and a
  real exit code.
- Extend the Makefile, matching the existing idiom:

  | Target | Runs |
  |---|---|
  | `make jit-up` | MinIO + runner + CRD + controller |
  | `make jit-verify` | `scripts/verify-jit.sh` → `.workflow/verify-jit.md` |
  | `make jit-down` | remove controller, runner, MinIO, and any leftover containers |
  | `make check STEP=NN` | run `scripts/checks/SNN.sh` |

- README section: the wedged-finalizer escape hatch (manual `tofu destroy`, then patch
  the finalizer off).

**Checkpoint** `scripts/checks/S17.sh`: `make jit-verify` passes J1-J11, and
`make verify` still reports 17 PASS in `voting-a`.

The four that matter:
- **J4** delete a Deployment → infra keeps running, other workloads unaffected
- **J5** redeploy inside the window → same containers, data intact
- **J8** delete a namespace → immediate teardown, the other namespace untouched
- **J9** controller restart → orphan still detected

---

## Done

- [x] `make all` and `make jit-verify` both green from a cold `make destroy` — *amended by S17's review*:
      `make all` now targets the `voting-a` overlay (`app/Makefile` defaults `NS`/`KUSTOMIZE_DIR` to it),
      tenants never run in `default`, and the cold order needs `make jit-down` plus a cluster-creating
      `make deploy` before `jit-up`. The recipe and its traps are in the README's "From cold"; the runs
      that established it are in `docs/evidence/s17-cold-path*.log`. **Run green and committed**:
      `docs/evidence/s17-cold-path-green.log` — `17 PASS, 0 FAIL` then `11 PASS, 0 FAIL`, cold, after the
      fourth trap was closed. That trap was the blocker this item was left open on: a Postgres volume
      outliving its container, holding a password the new stack does not use. A container removal takes its
      volume (`tofu destroy` always did; `scripts/jit-down.sh`'s by-name sweep now does too), because the
      data directory is where the password lives. Gate re-run on the final code:
      `docs/evidence/s17-final-gate.log`.
- [ ] `docs/todo.md` boxes all ticked, with the checkpoint output that justified each
- [ ] Review section in `todo.md`: what changed from the design and why
- [ ] `docs/lessons.md` for anything that had to be reworked
- [ ] A short note on what production needs that this omits: snapshot before destroy,
      `retain: true`, stopping rather than running during retention, async
      provisioning, real IAM
