# JIT Infra PoC

**Infrastructure that appears when an app deploys and goes away when the app does.**

A tenant annotates a Deployment; a controller provisions real infrastructure outside the
cluster; deleting the app starts a retention clock; deleting the namespace tears
everything down immediately.

Proof of concept on k3d. **Not production grade** — see [Limits](#limits).

---

## What it does

```yaml
kind: Deployment
metadata:
  name: vote
  namespace: voting-a
  annotations:
    jit.infra/redis:    '{"maxmemory":"128mb"}'
    jit.infra/postgres: '{"db":"voting"}'
    jit.infra/pgadmin:  '{}'
```

`kubectl apply` and three containers appear on the Docker network. `kubectl delete ns voting-a`
and they are gone. The tenant never touches Terraform, a CRD, or a service catalogue.

## How it works

An in-cluster controller owns the **lifecycle**; an out-of-cluster runner owns the
**provisioning**. Terraform modules live in their own repo, versioned by git ref, and
never enter the cluster. The controller holds no Docker socket and no state credentials —
it makes an authenticated HTTP call and writes the results back into Kubernetes.

Infrastructure is provisioned as Docker containers on the host daemon, outside k3d, and
consumed from inside the cluster via a Service with no selector plus an EndpointSlice —
the same pattern you would use for an RDS endpoint.

### Architecture at a glance

```
+---------------------------------------------------------------------+
|                     k3d cluster  voting-app                         |
|                                                                     |
|   vote --> worker --> result          jit-controller                 |
|                                           |                         |
|   Service + EndpointSlice (no selector)   |  HTTP + bearer token    |
+-------------------------------------------+-------------------------+
                                            v
+---------------------------------------------------------------------+
|               docker network  k3d-voting-app                        |
|                                                                     |
|   .10  jit-runner  (holds docker.sock, calls tofu)                  |
|   .11  MinIO       (S3-compatible TF state backend)                 |
|   .100 redis       (provisioned per-tenant)                         |
|   .101 postgres    (provisioned per-tenant)                         |
|   .102 pgadmin     (provisioned per-tenant)                         |
+---------------------------------------------------------------------+
```

Solid lines are control flow; dotted lines (Service + EndpointSlice) are data. The
controller never touches Docker and never holds state credentials — that separation is
the point of the split-plane design.

> **Full Mermaid diagrams:** [`docs/jit-infra-flows.md`](docs/jit-infra-flows.md) —
> create flow, soft delete, hard delete, claim state machine, resync loop, and component
> layout.

### The two things worth knowing

**The Namespace owns the lifecycle, not the Deployment.** Prod is one namespace per app,
so namespace-owned is app-owned. Rollouts and `kubectl delete deploy` do not touch
infrastructure; a Deployment is a spec revision, not an application.

**Cleanup has two speeds.** Deleting a Deployment marks the claim `Orphaned` and starts a
TTL — redeploy inside the window and the same container comes back with its data intact.
Deleting the Namespace destroys immediately, ignoring the TTL. Accidents get a grace
period; deliberate acts do not.

## What this simulates

| Prod | Here |
|---|---|
| AWS control plane | host Docker daemon |
| EKS | k3d cluster `voting-app` |
| Versioned TF modules in a repo | `jit-modules` repo, pinned by git ref |
| TF runs in CI with cloud creds | `jit-runner` container holding the Docker socket |
| S3 state + locking | MinIO, S3 backend, per-namespace key prefix |
| ElastiCache / RDS | `redis` / `postgres` containers |

Not simulated: IAM, network policy, approval gates, provisioning latency.

---

## Prerequisites

- **k3d**, **kubectl**, **Docker**
- **OpenTofu** (arm64 build on Apple silicon)
- The **voting app repo** in the same VS Code workspace, read-only
- Cluster created with `--subnet 172.19.0.0/16` — the static IP allocation depends on it

## Running it

```bash
# 1. Start the JIT stack (MinIO + runner + CRD + controller)
make jit-up

# 2. Deploy one or two demo tenants
kubectl apply -k app/kustomize/overlays/voting-a   # primary demo
kubectl apply -k app/kustomize/overlays/voting-b   # second tenant, same base

# 3. Verify
make jit-verify          # lifecycle suite J1-J11 (exits non-zero on failure)
make verify              # app checks R1-R17 (NS=voting-a by default)

# 4. Tear down
make jit-down            # remove the stack, claims, and IPAM ledger
```

The two demo namespaces come from one base; only the namespace, ingress hosts, and
pgAdmin's host port differ (see `app/kustomize/overlays/voting-b/kustomization.yaml`).

### Make targets

| Target | What it does |
|---|---|
| `make jit-up` | Boot the out-of-cluster half: MinIO, runner, CRD, controller |
| `make jit-verify` | Run the J1-J11 lifecycle suite; writes `.workflow/verify-jit.md` |
| `make jit-down` | Tear down the stack; waits for claims to disappear |
| `make verify` | Run the app's R1-R17 in NS (default `voting-a`); writes `.workflow/verify.md` |
| `make check STEP=NN` | Run one frozen checkpoint from `scripts/checks/` |
| `make all` | `make jit-up` + `make verify` (from `app/Makefile`) |
| `make destroy` | Delete the k3d cluster entirely |

### Key lifecycle checks

| Check | What it proves |
|---|---|
| **J4** | Delete a Deployment -> infra keeps running, other workloads unaffected |
| **J5** | Redeploy inside the TTL window -> same containers, data intact |
| **J8** | Delete a namespace -> immediate teardown, other namespaces untouched |
| **J9** | Controller restart -> the orphan is still detected |

### From cold

`make destroy` deletes the cluster, so a cold start is two passes of the app's own loop.
Every line below is load-bearing: the green run is `docs/evidence/s17-cold-path-green.log`,
and the three runs before it show each defect the green run fixed.

```bash
make destroy                      # delete the cluster
make jit-down                     # idempotent on an empty cluster
make jit-up                       # imports the controller image, starts the stack
make all                          # 17 PASS, 0 FAIL
make jit-verify                   # 11 PASS, 0 FAIL
```

---

## Layout

```
.
+-- README.md                <- you are here
+-- RUNBOOK.md               <- the page to keep open while building
+-- Makefile                 <- root orchestration (jit-up, jit-down, verify, check)
|
+-- app/                     <- copy of the voting app (the reference repo is read-only)
|   +-- Makefile             <- app build/deploy/verify (make all, make verify)
|   +-- kustomize/           <- base + per-tenant overlays (voting-a, voting-b)
|   +-- scripts/             <- build.sh, deploy.sh, verify.sh, cleanup.sh
|   +-- vote/                <- vote frontend
|   +-- worker/              <- background processor
|   +-- result/              <- result frontend
|
+-- jit-controller/          <- in-cluster operator (Python, kopf)
|   +-- main.py              <- claim lifecycle, IPAM, resync loop
|   +-- ipam.py              <- per-namespace IP block allocator
|   +-- test_ipam.py         <- unit tests for pure allocation logic
|
+-- jit-runner/              <- out-of-cluster provisioning service (Python, Flask)
|   +-- main.py              <- /v1/runs API, tofu init/apply/destroy
|   +-- deployment.yaml      <- Kubernetes Deployment for the runner
|
+-- jit-modules/             <- Terraform/OpenTofu modules (one per infra type)
|   +-- modules/
|       +-- redis/
|       +-- postgres/
|       +-- pgadmin/
|
+-- deploy/                  <- bootstrap: cluster, MinIO, runner, CRD
|   +-- minio.sh             <- MinIO setup (bucket, credentials)
|   +-- runner.sh            <- jit-runner container bootstrap
|   +-- controller.yaml      <- controller Deployment + RBAC
|   +-- crd/
|       +-- infraclaim.yaml  <- InfraClaim CustomResourceDefinition
|
+-- scripts/
|   +-- jit-up.sh            <- bring the whole stack up
|   +-- jit-down.sh          <- tear it down (waits for claims)
|   +-- verify-jit.sh        <- J1-J11 lifecycle test suite
|   +-- checks/              <- frozen checkpoint scripts (S-1 through S17)
|
+-- docs/
    +-- jit-infra-poc.md     <- design note (v4) -- the source of truth
    +-- jit-infra-flows.md   <- Mermaid diagrams for all flows
    +-- build-plan.md        <- the 18-step implementation plan
    +-- todo.md              <- step tracker (check + review boxes)
    +-- lessons.md           <- corrections that became rules
    +-- 01-jit-poc.md        <- working rules for AI agent sessions
    +-- decisions/           <- Architecture Decision Records (template)
    +-- evidence/            <- verbatim run logs and probe scripts
    +-- reviews/             <- review prompts and findings (S08-S17)
```

---

## Key documents

### Design & architecture

| Document | What it covers | Read when |
|---|---|---|
| [`docs/jit-infra-poc.md`](docs/jit-infra-poc.md) | **Design note (v4)** — core decisions: annotation on Deployment, ownership on Namespace, two-speed cleanup, claim lifecycle | Something feels wrong, or you need to understand *why* |
| [`docs/jit-infra-flows.md`](docs/jit-infra-flows.md) | **Mermaid diagrams** — create, soft delete, hard delete, claim state machine, resync loop, component layout | You need a visual overview of a specific flow |
| [`docs/01-jit-poc.md`](docs/01-jit-poc.md) | **Working rules** — scope, method, code conventions for agent-driven implementation | Starting a new AI coding session |
| [`docs/decisions/`](docs/decisions/) | **ADRs** — architecture decision records (template at `0000-template.md`) | A decision needs formal documentation |

### Implementation & tracking

| Document | What it covers | Read when |
|---|---|---|
| [`RUNBOOK.md`](RUNBOOK.md) | **Daily page** — the implement -> review -> resolve loop, one step at a time | Every session. Keep it open. |
| [`docs/build-plan.md`](docs/build-plan.md) | **18 steps** — each with scope, checkpoints, and acceptance criteria | Checking what a step involves |
| [`docs/todo.md`](docs/todo.md) | **Tracker** — check and review boxes per step, settled decisions | Seeing where things stand |

### Learning & evidence

| Document | What it covers | Read when |
|---|---|---|
| [`docs/lessons.md`](docs/lessons.md) | **Rules from rework** — each entry is a rule with the evidence that produced it | Something looks like a pattern you've seen before |
| [`docs/evidence/`](docs/evidence/) | **Run logs and probes** — verbatim output from checkpoints and diagnostic scripts | Verifying a claim or reproducing a run |
| [`docs/reviews/`](docs/reviews/) | **Review prompts and findings** — S08 through S17, each with a prompt and findings | Understanding what a review caught |

---

## Claim state machine

The novel logic — everything in Stage C of the build plan exists to make this correct.

```
                  +----------+
     annotation   |          |  apply succeeded
     seen -------> | Pending  | ---------------> Ready
                  |          |                  |  ^
                  +----------+                  |  |
                       |                        |  | a reference
                  runner error                  |  | returns
                       |                        v  |
                       v                   +----------+
                  +----------+             |          |
                  |  Failed  |             | Orphaned |
                  |          |             |          |
                  +----------+             +----------+
                       |                   |         |
                  retry with               |         | namespace
                  backoff                  |         | deleted
                       |                   v         v
                       +---> Pending    +----------+
                                      | Deleting  |
                                      |           |
                                      +----------+
                                           |
                             destroy done   |   destroy failed
                                  +---------+---------+
                                  v                     v
                                [*]              (finalizer held,
                                                  retry on next
                                                  resync tick)
```

Two transitions carry the design:

- **Orphaned -> Ready** is resurrection. It is why a rollout costs nothing.
- **Orphaned -> Deleting** on namespace delete bypasses the TTL. Soft and hard paths
  converge on the same destroy, at different speeds.

> Full state diagram in Mermaid: [`docs/jit-infra-flows.md` S4](docs/jit-infra-flows.md)

---

## Troubleshooting

### pgAdmin shows no server

`var.share_dir` must point at a directory visible to the Docker daemon. The runner's own
filesystem is not — Docker silently creates an empty *directory* for a bind source it
cannot see, so pgAdmin comes up with no server registered. The deploy scripts write the
servers JSON to `$HOME/.jit-host-share/`.

### Namespace stuck in `Terminating`

The finalizer is held because the runner call failed. Escape hatch:

```bash
# 1. Destroy the infra manually
export AWS_ACCESS_KEY_ID="$(grep ^MINIO_ROOT_USER= deploy/.env | cut -d= -f2-)"
export AWS_SECRET_ACCESS_KEY="$(grep ^MINIO_ROOT_PASSWORD= deploy/.env | cut -d= -f2-)"
tofu init -backend-config=bucket=jit-state \
  -backend-config=key="ns/<ns>/<module>/terraform.tfstate" \
  -backend-config=endpoint=http://127.0.0.1:9000 -backend-config=region=us-east-1 \
  -backend-config=access_key="$AWS_ACCESS_KEY_ID" -backend-config=secret_key="$AWS_SECRET_ACCESS_KEY" \
  -backend-config=skip_credentials_validation=true -backend-config=skip_metadata_api_check=true \
  -backend-config=force_path_style=true
tofu destroy -auto-approve -var name=<ns>-<module> -var network=k3d-voting-app -var ip=<ip>
#    redis needs nothing more. postgres also needs -var postgres_password=<secret>,
#    and pgadmin needs that *and* -var postgres_url=<address>:<port>.

# 2. Patch the finalizer off
kubectl patch infraclaim <ns>-<module> -n <ns> --type=json \
  -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]'

# 3. Clean up the IPAM ledger
kubectl get configmap jit-ipam -n default -o json \
  | jq --arg ns '<ns>' '.data.allocations |= (fromjson | del(.[$ns]) | tojson)' \
  | kubectl replace -f -

# 4. Or tear down the whole stack
make jit-down
```

### A step fails twice

Stop. That is usually a design problem wearing an implementation costume — go back to the
design note ([`docs/jit-infra-poc.md`](docs/jit-infra-poc.md)) rather than deeper into
the code.

---

## Limits

This is a proof of concept. Things it deliberately does not address:

- **No IAM or RBAC.** The runner has unrestricted Docker access.
- **No network policy.** All containers share one Docker bridge network.
- **No approval gates.** Anything annotated gets provisioned immediately.
- **No provisioning latency modelling.** Containers start in seconds, not minutes.
- **No multi-node scheduling.** Everything runs on one Docker host.
- **No Terraform locking.** MinIO provides the S3 backend but no DynamoDB-style lock table.
- **No snapshot or backup.** Soft delete covers the accident case; there is no point-in-time recovery.
- **No horizontal scaling.** One controller, one runner, one MinIO.
- **No monitoring or alerting.** Logs go to stdout.
- **No secret rotation.** Passwords are generated once and live until the infra is destroyed.

For production, start with the [design note](docs/jit-infra-poc.md) and work forward.
