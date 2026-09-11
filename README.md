# JIT Infra PoC

Infrastructure that appears when an app deploys and goes away when the app does.

A tenant annotates a Deployment; a controller provisions real infrastructure outside the
cluster; deleting the app starts a retention clock; deleting the namespace tears
everything down immediately.

Proof of concept on k3d. **Not production grade** - see [Limits](#limits).

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

`kubectl apply` and three containers exist. `kubectl delete ns voting-a` and they are
gone. The tenant never touches Terraform, a CRD, or a service catalogue.

## How it works

An in-cluster controller owns the **lifecycle**; an out-of-cluster runner owns the
**provisioning**. Terraform modules live in their own repo, versioned by git ref, and
never enter the cluster. The controller holds no Docker socket and no state credentials -
it makes an authenticated HTTP call and writes the results back into Kubernetes.

Infrastructure is provisioned as Docker containers on the host daemon, outside k3d, and
consumed from inside via a Service with no selector plus an EndpointSlice - the same
pattern you would use for an RDS endpoint.

Diagrams: [`docs/design/jit-infra-flows.md`](docs/design/jit-infra-flows.md)

### The two things worth knowing

**The Namespace owns the lifecycle, not the Deployment.** Prod is one namespace per app,
so namespace-owned is app-owned. Rollouts and `kubectl delete deploy` do not touch
infrastructure; a Deployment is a spec revision, not an application.

**Cleanup has two speeds.** Deleting a Deployment marks the claim `Orphaned` and starts a
TTL - redeploy inside the window and the same container comes back with its data intact.
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

## Layout

```
.
├── RUNBOOK.md              ← the page to keep open while building
├── .clinerules/            agent constraints, loaded automatically
├── app/                    copy of the voting app (the reference repo is read-only)
├── jit-modules/            terraform modules
├── jit-runner/             out-of-cluster provisioning service
├── jit-controller/         in-cluster operator
├── deploy/                 cluster, MinIO and runner bootstrap
├── scripts/checks/         checkpoint scripts - frozen, never edited
└── docs/
    ├── design/             design note, diagrams, superseded versions
    ├── build-plan.md       the 18 steps
    ├── todo.md             the tracker
    ├── lessons.md          corrections that became rules
    └── reviews/            review prompts and findings
```

## Documents

| File | Read it when |
|---|---|
| [`RUNBOOK.md`](RUNBOOK.md) | Every step. The only daily page. |
| [`docs/build-plan.md`](docs/build-plan.md) | Checking what a step involves |
| [`docs/todo.md`](docs/todo.md) | Where things are |
| [`docs/design/jit-infra-poc.md`](docs/design/jit-infra-poc.md) | Something feels wrong, or a review disputes intent |
| [`docs/design/jit-infra-flows.md`](docs/design/jit-infra-flows.md) | Before the controller steps |
| `docs/design/*-superseded.md` | Wondering why the design changed |

---

## Building it

Implementation is delegated to a local model, one step at a time, with a hard checkpoint
between steps and an adversarial review by a **different** model before the next one
starts.

```
Do S<N> from docs/build-plan.md
```

Full loop in [`RUNBOOK.md`](RUNBOOK.md). Two rules that matter:

- **Checkpoints are frozen.** All 18 were written in step S-1 before any implementation
  and are never edited. An agent that can edit its own gates has no gates.
- **The review runs in a new task on a different model.** A cleared context on the same
  model reproduces its own blind spots.

A step is done when its checkpoint prints `PASS` **and** a different model writes `CLEAR`
in `docs/reviews/SNN-findings.md`. Two boxes in the tracker, or it is not done.

## Prerequisites

- k3d, kubectl, Docker
- OpenTofu (arm64 build on Apple silicon)
- The voting app repo in the same VS Code workspace, read-only
- Cluster created with `--subnet 172.19.0.0/16` - the static addressing depends on it

## Running it

```bash
make jit-up                                        # MinIO + runner + CRD + controller

kubectl apply -k app/kustomize/overlays/voting-a   # the demo tenant
kubectl apply -k app/kustomize/overlays/voting-b   # a second one, same base
make jit-verify                                    # the lifecycle suite, J1-J11
make verify                                        # the app's R1-R17 (NS, default voting-a)
make jit-down                                      # remove the stack again
```

The two demo namespaces come from one base; only the namespace, the ingress hosts and
pgAdmin's host port differ (see `app/kustomize/overlays/voting-b/kustomization.yaml`).
`make jit-verify` deploys both itself - deploying *is* J1 - and `make verify` runs the
app's own checks in `voting-a`.

```bash
make check STEP=16           # one frozen checkpoint from scripts/checks/
```

`make jit-verify` writes `.workflow/verify-jit.md` and exits non-zero on the first
failure, unlike `make verify`, whose report always exits 0. The four checks that matter:

| | |
|---|---|
| **J4** | delete a Deployment → infra keeps running, other workloads unaffected |
| **J5** | redeploy inside the window → same containers, data intact |
| **J8** | delete a namespace → immediate teardown, other namespaces untouched |
| **J9** | controller restart → the orphan is still detected |

### From cold

`make destroy` deletes the cluster, so a cold start is two passes of the app's own loop. Every
line below is load-bearing: the green run is `docs/evidence/s17-cold-path-green.log`, and the three
runs before it - `s17-cold-path-gaps.log`, `-order.log`, `s17-cold-path.log` - each record what the
next missing line cost.

```bash
make jit-down                                  # the module containers live on the host, not the cluster
cd app && make destroy                         # the app, then the k3d cluster
cd app && make deploy                          # creates the cluster, then stops - the CRD is not there yet
make jit-up                                    # MinIO + runner + CRD + controller
kubectl create ns voting-a                     # namespaces are the platform's; kustomize does not create them
cd app && make all                             # the app into voting-a, then R1-R17
make jit-verify                                # J1-J11
```

(`app/Makefile` defaults `NS` and `KUSTOMIZE_DIR` to the `voting-a` overlay, so `make all`
lands in the demo namespace. Override them for `voting-b`: `make all NS=voting-b
KUSTOMIZE_DIR=./kustomize/overlays/voting-b`.)

Three things surprise people here, and all three are real:

- **`make deploy` stopping is the design, not a break.** `scripts/jit-up.sh` refuses to run without a
  cluster and `app/scripts/deploy.sh` refuses to apply the app without the CRD, so one of them has to
  go first. That first `deploy` is only there to create the cluster.
- **`make destroy` leaves the module containers running.** They live on the Docker daemon, outside the
  cluster, so they survive it - and their addresses have to be free before the next stack's empty IPAM
  ledger hands out the same ones. `make jit-down` is what removes them, together with the Postgres
  volume each one owns: a data directory carries its own password, so a volume that outlives its
  container makes the next stack's fresh password unusable
  (`FATAL: password authentication failed for user "postgres"`).
- **Tenants never run in `default`.** The base kustomization carries no namespace, so a bare
  `kubectl apply -k app/kustomize` (or a `make deploy` with `KUSTOMIZE_DIR` pointing at the base) puts
  the app in `default`, whose Ingress then claims `vote.localhost` - the host the `voting-a` demo owns -
  and `make jit-verify` refuses to run. Use the overlays, as above.

---

## Limits

Deliberate omissions, not oversights.

- **No snapshot before destroy.** `kubectl delete ns` takes the Postgres volume with it, and so
  does any teardown: a container removal takes the volume it owns, because the data directory is
  where that password lives. The soft-delete window covers the accident that matters; the
  deliberate act is unprotected on purpose, so the failure is visible rather than theoretical.
- **The runner holds the Docker socket.** That is the "cloud credential" of this
  simulation, and it is why nothing here should ever point at anything you care about.
- **Synchronous provisioning.** Containers start in seconds. Real RDS takes 5-15 minutes
  and forces async status machinery this PoC never exercises - the biggest divergence
  from prod.
- **No IAM, no multi-tenancy, no approval gates.** A local PoC cannot teach you anything
  useful about those.
- **Orphaned infrastructure keeps running** during the retention window, and in prod
  would keep billing. Stopping the container and retaining its volume is the right
  answer; it is noted, not built.

## If it goes wrong

**Namespace stuck in `Terminating`.** A destroy failed and the finalizer is held, so the
claim cannot be deleted and the namespace cannot finish terminating. This is the most
likely way to lose an afternoon. The escape hatch, in order:

```bash
# 1. See what is wedged and who is holding it.
kubectl get infraclaims -n <ns> -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,IP:.status.allocatedIP,EXPIRES:.status.expiresAt

# 2. Destroy the workspace by hand. Copy the module out, point tofu at the same
#    state key in MinIO, and pass the same variables the controller would have:
#    name/ip/network always, plus the credentials for postgres and pgadmin.
cp -r jit-modules/modules/<module> /tmp/wedged && cd /tmp/wedged
export AWS_ACCESS_KEY_ID="$(grep ^MINIO_ROOT_USER= <repo>/deploy/.env | cut -d= -f2-)"
export AWS_SECRET_ACCESS_KEY="$(grep ^MINIO_ROOT_PASSWORD= <repo>/deploy/.env | cut -d= -f2-)"
tofu init -backend-config=bucket=jit-state \
  -backend-config=key="ns/<ns>/<module>/terraform.tfstate" \
  -backend-config=endpoint=http://127.0.0.1:9000 -backend-config=region=us-east-1 \
  -backend-config=access_key="$AWS_ACCESS_KEY_ID" -backend-config=secret_key="$AWS_SECRET_ACCESS_KEY" \
  -backend-config=skip_credentials_validation=true -backend-config=skip_metadata_api_check=true \
  -backend-config=force_path_style=true
tofu destroy -auto-approve -var name=<ns>-<module> -var network=k3d-voting-app -var ip=<ip>
#    redis needs nothing more. postgres also needs -var postgres_password=<secret>,
#    and pgadmin needs that *and* -var postgres_url=<address>:<port> - neither has a
#    default, and without them the destroy fails on "No value for required variable".
#    The controller takes both from the jit-postgres Secret: POSTGRES_PASSWORD, and
#    address/port joined as "<address>:<port>". Add -var http_port=<n> for pgadmin
#    only if it was not published on the module's default 5050.
#    Run this on the host, not inside the jit-runner container, and pass
#    -var share_dir="$HOME/.jit-host-share": pgadmin's module bind-mounts
#    ${var.share_dir}/pgadmin-servers-<name>.json, and that directory is where
#    deploy/runner.sh writes it - visible to the Docker daemon, which the runner's own
#    filesystem is not. Docker silently creates an empty *directory* for a bind source
#    the daemon cannot see, which is why pgAdmin would come up with no server
#    registered (var.share_dir, fixed in S17). A destroy removes the container either
#    way; the path has to match what the module wrote only so the plan is coherent.

# 3. Take the finalizer off, which lets the claim and its namespace go.
kubectl patch infraclaim <ns>-<module> -n <ns> --type=json \
  -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]'
#    Patch the finalizer off and the controller never runs its release, so the
#    namespace's IP block stays in the jit-ipam ledger and is lost to the next
#    namespace that needs one. Drop the entry by hand, or let step 4 remove the whole
#    ledger with the stack:
kubectl get configmap jit-ipam -n default -o json \
  | jq --arg ns '<ns>' '.data.allocations |= (fromjson | del(.[$ns]) | tojson)' \
  | kubectl replace -f -

# 4. Or leave the stack entirely.
make jit-down
#    That takes the stack, the claims and the IPAM ledger with it - and it waits for the
#    claims to actually disappear, because a stack that comes down mid-destroy leaves
#    them Terminating and they return as *Ready* with nothing behind them, which stops
#    the tenant being re-provisioned at all. It does not touch the tenant namespaces:
#    their Deployments survive, and nothing re-creates the claims on the way back up -
#    kopf does not replay create for objects that already existed, and an unchanged
#    `kubectl apply` is a no-op. After `make jit-up`, touch the annotated Deployment and
#    the claims come back:
#      kubectl rollout restart deployment/<name> -n <ns>
#    (Verified by running the bounce: jit-down, jit-up, touch -> three claims Ready and
#    the ledger rebuilt as {"<ns>": {"offset": 0, "count": 3}}.)
```

A destroy that fails for the *same* reason twice is a design problem wearing an
implementation costume - go back to the design note rather than deeper into the code.

**A step fails twice.** Stop. That is usually a design problem wearing an implementation
costume - go back to the design note rather than deeper into the code.
