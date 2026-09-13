# JIT Infra PoC - Design Note (v4)

Date: 2026-09-01
Scope: proof of concept on k3d. Not production grade.
Supersedes: [v1](./jit-infra-poc-v1-superseded.md) (modules in the controller image),
[v2](./jit-infra-poc-v2-superseded.md) (Deployment-owned, two tiers),
[v3](./jit-infra-poc-v3-superseded.md) (annotation on the Namespace, single hard delete).

Context read:
- `local-ai-dev-workflow-voting-app` README, `docs/SCRIPTS-GUIDE.md`,
  `docs/MAKEFILE-GUIDE.md` - `vote → redis → worker → postgres ← result`, k3d cluster
  `voting-app`, Kustomize, Traefik, 8081:80 / 8082:443, arm64. Scripts live in
  `scripts/` (`build|deploy|verify|cleanup.sh`) behind a Makefile; verification is
  R1-R17 written to `.workflow/verify.md`; credentials come from a generated
  `kustomize/postgres-secret.env`.
- `DevSecOps-PetClinic/01-JenkinsOnDocker-K8sAgentsOnK3D.md` - working precedent for a
  Docker container on the k3d network, and for agent pods reaching it.
- Stated prod conventions: **one namespace per app**, and **namespaces are managed by
  the platform team, not tenants.**

## Decision

Tenants annotate their **Deployments**. The controller creates claims owned by the
**Namespace**. Cleanup is two-speed: deleting a Deployment starts a retention clock;
deleting the Namespace destroys immediately.

Authoring surface and ownership are deliberately different objects. Tenants write
where they have write access; lifecycle sits where it belongs.

## Why the surfaces are split

v3 put the annotation on the Namespace, which is coherent but unusable - tenants
cannot edit namespaces. v2 put both the annotation and the ownership on the
Deployment, which broke because a Deployment is a spec revision, not an application.

Splitting them takes the good half of each:

| | Object | Why |
|---|---|---|
| **Authoring** | Deployment annotation | Tenant-writable. Infra is declared next to the thing that needs it. |
| **Ownership** | `ownerReference` → Namespace | Survives rollouts and Deployment churn. One namespace per app, so this is app-scoped. |
| **Soft trigger** | Deployment disappearance | Watched, not owned. Starts the retention clock. |
| **Hard trigger** | Namespace deletion | Kubernetes GC → finalizer → immediate destroy. |

Nothing about this is exotic - the claim is derived state, and the annotation is the
only thing a human writes.

## Cleanup: soft and hard

This is the part v3 got wrong by having only one speed.

**Soft clean - the Deployment goes.** The claim is not deleted (its owner, the
Namespace, is still alive). The controller marks it `Orphaned` and stamps
`expiresAt = now + TTL`. Infra keeps running. The Secret, Service and EndpointSlice
stay in place.

- **Redeploy within the window** → claim returns to `Ready`, same container, same
  data. Nothing is reprovisioned. A rollout that deletes and recreates a Deployment
  costs nothing.
- **Window expires** → the sweep destroys it, exactly as a namespace delete would.

**Hard clean - the Namespace goes.** GC deletes the claims, each finalizer calls
destroy immediately, `expiresAt` is ignored. The platform team deleting a namespace is
an unambiguous act; there is nothing to protect against.

```
Deployment deleted ──► claim Orphaned, expiresAt = +30d
                          │
     redeploy ◄───────────┤ (resurrect: same infra, same data)
                          │
     TTL expires ─────────► destroy

Namespace deleted ──────► destroy now
```

TTL comes from the annotation, defaulting to 30 days:

```yaml
annotations:
  jit.infra/redis: '{"maxmemory":"128mb","softDeleteTTL":"30d"}'
```

For the PoC, demos run with `2m` - a 30-day window is not a testable assertion.

**What "orphaned" costs.** The infra keeps running and, in prod, keeps billing. The
cheaper shape is to stop the container and retain its volume - `docker stop` locally,
snapshot-and-delete in AWS - and start it again on resurrection. The module would carry
a `running` bool and the soft path would `tofu apply -var running=false`. Worth
knowing, not worth building here; the PoC leaves it running and shows the expiry in
status so the cost is at least visible.

## How the controller knows a Deployment is gone

Not by trusting a delete event. Events are missed when the controller restarts.

A periodic resync lists claims and asks: does any live Deployment in this namespace
still annotate this module? If yes, `Ready`. If no, `Orphaned` with an expiry. If it
was already `Orphaned` and a Deployment has reappeared, clear the expiry.

Two things fall out of that for free:

- **Refcounting without a counter.** `vote` and `worker` both annotating
  `jit.infra/redis` produce one claim, and it only goes `Orphaned` when the last
  referencing Deployment disappears. The reference set is derived on every pass, so
  there is no counter to get out of sync.
- **Resurrection.** Redeploy is just the same query returning a different answer.

The delete watch still exists so the common case is fast; the resync is what makes it
correct.

## What this simulates

| Your prod | This PoC | Why it maps |
|---|---|---|
| AWS control plane | Host Docker daemon | The API that creates infra, outside the cluster |
| EKS | k3d cluster `voting-app` | Where apps run |
| One namespace per app, platform-managed | Same | Ownership boundary is the same object |
| TF modules in a repo, versioned | `jit-modules` repo, pinned by ref | External versioned artifact |
| TF runs in CI with cloud creds | `jit-runner`, holds the Docker socket | Credentials never enter the cluster |
| S3 state + locking | MinIO, S3 backend, `use_lockfile` | Per-namespace key prefix |
| ElastiCache / RDS | `redis` / `postgres` containers | Data plane outside the cluster |

Not simulated: IAM, network policy, approval gates, provisioning latency.

## Tenant surface

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

`kubectl apply` and three containers exist. The tenant never touches the Namespace, a
CRD, or Terraform.

**Postgres is on this path with no guardrail, deliberately.** The soft-delete window
now covers the accident that mattered - `kubectl delete deploy` no longer destroys
anything. What remains unprotected is `kubectl delete ns`, which only the platform
team can do. That is a reasonable place to leave the PoC, and the follow-up work
(snapshot before destroy, `retain: true`) belongs in the write-up.

## Shape

Sequence and state diagrams: [jit-infra-flows.md](./jit-infra-flows.md).

```
  ┌─ k3d cluster "voting-app" ──────────────────────────────────┐
  │  Namespace voting-a          (platform-managed)             │
  │    ├── vote  (annotations: redis, postgres, pgadmin)        │
  │    ├── worker (annotation: redis)                           │
  │    └── result                                               │
  │                                                             │
  │  jit-controller (kopf, 1 replica)                           │
  │    - Deployment annotations → claim per module               │
  │    - ownerReference → Namespace, finalizer on the claim     │
  │    - resync: no referencing Deployment → Orphaned + expiry  │
  │    - writes Secret + Service + EndpointSlice into the ns    │
  │         │  HTTP + bearer token → 172.19.0.10:8080           │
  └─────────┼───────────────────────────────────────────────────┘
            ▼
  ┌─ docker network k3d-voting-app (172.19.0.0/16) ─────────────┐
  │  jit-runner .10   (FastAPI + tofu, docker.sock)             │
  │    POST /v1/runs · DELETE /v1/runs/{workspace}              │
  │      ├── module at git ref ──► jit-modules repo             │
  │      ├── state ──► MinIO .11  (key = ns/module)             │
  │      └── tofu apply ──► Docker daemon                       │
  │                                                             │
  │  voting-a: redis .100  postgres .101  pgadmin .102          │
  │  voting-b: redis .110  postgres .111  pgadmin .112          │
  └─────────────────────────────────────────────────────────────┘
```

## Claim identity and idempotence

The claim is named `<namespace>-<module>`, derived from the namespace and the module,
**not** the Deployment. So `vote` and `worker` both asking for Redis compute the same
name and get one Redis.

Re-applying a Deployment computes the same name; the create returns `AlreadyExists`
and the controller does nothing. `tofu apply` against existing state is a second
no-op. Two guards, which is right for something that creates databases.

**Conflicting params.** If `vote` asks for 128mb and `worker` asks for 512mb, first
writer wins and the controller records a warning condition on the claim naming both
Deployments. Silently flip-flopping the container between two sizes on every resync
would be worse than an unresolved warning.

## Networking

One Docker network, fixed subnet, static IPs - the PetClinic pattern.

```
k3d cluster create voting-app --subnet 172.19.0.0/16 \
  -p "8081:80@loadbalancer" -p "8082:443@loadbalancer" --agents 1
```

`.10` runner, `.11` MinIO, `.100-199` provisioned infra in blocks of ten per
namespace, allocated by the controller through a `jit-ipam` ConfigMap. Static IPs are
the local analogue of a stable RDS endpoint: the address is known before the container
exists, so the Service and EndpointSlice never go stale.

Pods reach infra through a **Service with no selector plus an EndpointSlice** - the
standard way to consume an external endpoint, and what you would do for RDS.

**What the precedent proves.** In the PetClinic setup the agent pods reach Jenkins via
the host's LAN IP and published ports, not via `172.19.0.6`. So pod → container is
proven; pod → *Docker-network IP* is the untested bit. It should work - pod traffic to
a non-cluster CIDR routes out through the node and k3s masquerades it - but Phase 1
confirms it with a bare `kubectl run ... redis-cli -h 172.19.0.100` before anything is
built. Fallback is the proven path: host port plus `host.k3d.internal`. It is the
fallback rather than the default because of the 80/8080 lesson - one host port per
container will hit that again.

## Readiness gate

Pods read connection details via `secretKeyRef` with `optional: false`. The kubelet
will not start a pod until the Secret exists. No initContainer, no webhook, no status
conditions. `CreateContainerConfigError` means the infra is not ready.

## Components

| Component | Where | What |
|---|---|---|
| `jit-modules` | git repo | `modules/redis`, `modules/postgres`, `modules/pgadmin`. `kreuzwerker/docker` provider, static IP param, outputs address/port/URL. |
| `jit-runner` | container `.10` | FastAPI + `tofu`, Docker socket mounted. Fetches module at a git ref, `tofu init` against S3 backend, `apply`/`destroy`. |
| MinIO | container `.11` | State backend, key `ns/<namespace>/<module>/terraform.tfstate`, `use_lockfile = true`. |
| `InfraClaim` CRD | cluster | Spec `{module, moduleVersion, params, softDeleteTTL}`. Status `{phase, referencedBy[], expiresAt, outputsSecret, endpoint, message}`. Internal. |
| `jit-controller` | cluster | kopf. Deployment watch + periodic resync. Phases: `Pending → Ready → Orphaned → Deleting`. |
| `jit-ipam` | ConfigMap | namespace → address block. |

`referencedBy` is recomputed each resync, not maintained incrementally. Derived state
cannot drift.

## Failure modes handled

1. **Runner unreachable.** Claim `Failed`, error in status, kopf retries. Secret never
   appears, pods never start. Visible.
2. **Partial apply.** `tofu apply` is idempotent; the controller re-calls with the same
   workspace. No ledger, no GC sweep - out of scope, and said plainly.
3. **Destroy fails.** Finalizer held, namespace stuck in `Terminating`, error in
   status. Escape hatch documented: manual `tofu destroy`, then patch the finalizer off.
4. **Controller down when a Deployment is deleted.** The resync catches it on restart.
   The clock starts late, which is the safe direction to be wrong in.

## Verification

TTL set to `2m` for the demo.

| # | Check |
|---|---|
| J1 | Deploy into `voting-a` → three claims `Ready`, three containers on `.10x` |
| J2 | Secrets, Services, EndpointSlices exist; R1-R17 rework passes (see build plan S16) |
| J3 | pgAdmin reachable, Postgres server registration works |
| J4 | `kubectl delete deploy vote` → claims go `Orphaned` with `expiresAt`; **containers still running**; worker still functioning |
| J5 | Redeploy within the window → claims `Ready`, **same containers**, tally intact, nothing reprovisioned |
| J6 | Delete `vote`, wait past TTL → containers destroyed, Secrets and Services removed |
| J7 | `vote` and `worker` both annotate redis; delete only `vote` → claim stays `Ready` (last-reference rule) |
| J8 | `kubectl delete ns voting-b` → its containers destroyed **immediately**, expiry ignored, `voting-a` untouched |
| J9 | Kill the controller, delete a Deployment, restart → resync marks it `Orphaned` |
| J10 | Stop the runner, deploy → claims `Failed` with a readable message, pods do not start |
| J11 | MinIO shows one state object per namespace-module under distinct prefixes |

J4 and J5 are the soft path. J8 is the hard path. J7 is the refcount rule. J9 is the
one most designs skip.

## Demo

Two namespaces from the same Kustomize base. Delete a Deployment in one - nothing
happens, and it comes back instantly. Delete the namespace - three containers vanish
while the other namespace keeps running.

## Roads not taken

- **Annotation on the Namespace** ([v3](./jit-infra-poc-v3-superseded.md)): coherent,
  but tenants have no write access to namespaces.
- **Deployment-owned** ([v2](./jit-infra-poc-v2-superseded.md)): would win if
  namespaces were per-team. They are per-app.
- **Single hard delete**: what v3 had. Any Deployment delete became a data-loss event,
  which made rollouts frightening.
- **Stopping containers during the retention window**: the correct cost answer and the
  right prod shape (`running` var, or snapshot-and-delete). Left out to keep the PoC's
  soft path to one state transition.
- **Modules in the controller image** ([v1](./jit-infra-poc-v1-superseded.md)):
  simpler, but credentials end up in-cluster and modules stop being versioned.
- **Async runner with a queue**: correct for real provisioning latency. The biggest
  divergence from prod, where RDS's 5-15 minutes forces the whole async status machinery.

## Open questions

- [ ] Annotation edited on a live Deployment - re-apply, or refuse? Re-apply will
      recreate Redis and drop the queue.
- [ ] Should `Orphaned` infra be visible to the tenant, and where? A printer column on
      the claim is free, but tenants may not have read access to claims.
- [ ] IP block reuse after teardown: immediate, or quarantined a cycle? Immediate risks
      a stale EndpointSlice pointing at another namespace's container.
- [ ] Does a Deployment scaled to zero count as present? Currently yes - it still exists.
- [ ] What does a production version need that this omits: snapshot before destroy,
      `retain: true`, stopping rather than running during retention, async provisioning.

## Effort

~5-6 days. Runner and modules 1.5, controller and CRD 2 (the resync and soft-delete
state machine is the new work), migrating the app 1, verify script the rest.

Phase 4 - stripping Redis and Postgres out of `kustomize/` - is the error-prone day.
Do it after Phase 3 verifies, so a broken app is unambiguously the migration's fault.
