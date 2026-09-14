# The Voting App

The JIT PoC deploys a **voting application** as its tenant workload. The app lives in
`app/` and has its own build, deploy, and verify lifecycle. This document is the bridge
between the JIT project and the app — read the app's own README for the full detail.

> **App README:** [`app/README.md`](../app/README.md) — architecture, all 17
> requirements (R1-R17), gap analysis, and component walkthrough.
>
> **App guides:** [`app/docs/SCRIPTS-GUIDE.md`](../app/docs/SCRIPTS-GUIDE.md) for the
> build/deploy/verify scripts, [`app/docs/MAKEFILE-GUIDE.md`](../app/docs/MAKEFILE-GUIDE.md)
> for the make targets.

## What it is

A distributed voting application with this data flow:

```
vote (Flask)  →  redis (queue)  →  worker (Python)  →  postgres  ←  result (Flask)
```

- **vote/** — Flask frontend, enqueues votes to Redis via `RPUSH`
- **worker/** — Python background processor, pops from Redis (`BLPOP`), writes to Postgres
- **result/** — Flask frontend, reads tally from Postgres, auto-refreshes
- **redis** — message queue (provisioned by JIT, not in the cluster)
- **postgres** — database (provisioned by JIT, not in the cluster)

The vote and result frontends are deployed inside the cluster as Kubernetes Deployments.
Redis, Postgres, and pgAdmin are **not in the cluster** — they are Docker containers
provisioned on the k3d network by the JIT controller and runner (see
[how annotations map to infrastructure](annotation-to-state.md)).

## What the JIT project did to it

The voting app was built first as a standalone project. The JIT project then:

1. **Moved the stateful tiers out** (build-plan S15) — Redis, Postgres, and pgAdmin
   removed from `app/kustomize/` and replaced with JIT-provisioned containers
2. **Added JIT annotations** to the `vote` and `worker` Deployments
3. **Replaced credentials** — the app reads `jit-redis`, `jit-postgres` Secrets and
   Services instead of in-cluster Deployments
4. **Preserved the verification** — R1-R17 still pass, now reading from JIT-provisioned
   infrastructure

## Deployment model

The app uses **Kustomize** with a base and per-namespace overlays:

```
app/kustomize/
├── base/                          # Shared manifests
│   ├── vote-deployment.yaml       # vote + JIT annotations (redis, postgres, pgadmin)
│   ├── worker-deployment.yaml     # worker + JIT annotation (redis only)
│   ├── result-deployment.yaml     # result (no JIT annotations)
│   ├── vote-service.yaml
│   ├── result-service.yaml
│   └── ingress.yaml               # Traefik Ingress for vote.localhost / result.localhost
├── overlays/
│   ├── voting-a/                  # Namespace: voting-a (default, no patches)
│   └── voting-b/                  # Namespace: voting-b (patches: ingress hosts, pgadmin port)
```

Two namespaces from one base. `voting-a` keeps the base hosts (`vote.localhost` /
`result.localhost`). `voting-b` patches them to `vote-b.localhost` / `result-b.localhost`
because two Ingresses claiming the same host route unpredictably through Traefik.

## JIT annotations on the app

The `vote` Deployment declares three infrastructure needs:

```yaml
annotations:
  jit.infra/redis:    '{"module":"redis",   "moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'
  jit.infra/postgres: '{"module":"postgres","moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'
  jit.infra/pgadmin:  '{"module":"pgadmin", "moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'
```

The `worker` Deployment declares one:

```yaml
annotations:
  jit.infra/redis: '{"module":"redis", "moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'
```

Both reference `redis` — the controller's refcount rule means the redis claim stays
`Ready` until the **last** referencing Deployment is deleted (J7).

`voting-b` overrides the pgadmin annotation to use a different host port (`5051` instead
of `5050`) because two pgAdmin containers cannot share the same host port.

For the full annotation-to-infrastructure mapping, see
[Annotation to State](annotation-to-state.md).

## How the app consumes JIT infrastructure

The controller writes three Kubernetes resources per module into the app's namespace:

| JIT creates | App reads | Purpose |
|---|---|---|
| `Secret jit-redis` | `REDIS_URL` env var | Connection URL |
| `Secret jit-postgres` | `PGPASSWORD` env var (via `secretKeyRef`) | Database password |
| `Service jit-redis` | `redis://jit-redis:6379/0` | In-cluster DNS to the container |
| `Service jit-postgres` | `jit-postgres` hostname | In-cluster DNS to the container |
| `EndpointSlice jit-redis` | *(automatic)* | Routes Service traffic to the container's IP |
| `EndpointSlice jit-postgres` | *(automatic)* | Routes Service traffic to the container's IP |

The app never knows about Docker, IPAM, or the runner. It reads Secrets and connects to
Services — exactly how it would consume infrastructure in a production cluster.

## Running the app

```bash
# From the root — deploys into voting-a by default
make demo-up              # Full cold start: cluster + JIT + app + verify

# From app/ — app-only lifecycle
cd app
make deploy               # Create cluster, build images, apply kustomize
make verify               # Run R1-R17
make all                  # deploy + verify
make destroy              # Delete everything (cluster included)
```

The root `make demo-up` is the normal path — it handles the JIT stack and the app
together. The app's own Makefile is for when you're working on the app in isolation.

## Verification (R1-R17)

| Category | Checks | What they prove |
|---|---|---|
| Functional | R1-R6 | Vote page works, votes flow through Redis → Worker → Postgres, results display |
| Data | R7-R9 | Schema exists, queue survives worker restart, tally survives Postgres restart |
| Platform | R10-R17 | Probes, resource limits, single config, ingress, no NodePort, arm64, `/healthz`, Secret-based credentials |

```bash
make verify NS=voting-a     # Default namespace
make verify NS=voting-b     # Second namespace
```

Results go to `app/.workflow/verify.md`. The root `make verify` wraps this and exits
non-zero if any R-check fails.

## Architecture notes

- **One namespace per app** — the stated production convention. `voting-a` and `voting-b`
  are two instances of the same app, not two apps in one namespace.
- **No stateful workloads in the cluster** — Redis, Postgres, and pgAdmin are Docker
  containers on the k3d bridge network, provisioned by the JIT controller.
- **Credentials come from Secrets** — the controller writes `jit-postgres` with the
  generated password; the app reads it via `secretKeyRef`. No credentials in manifests.
- **The worker's init container** waits for Postgres to be ready, then creates the
  `votes` table idempotently. Postgres is reached through the `jit-postgres` Service.
- **Ingress** is Traefik (bundled with k3d). `vote.localhost` and `result.localhost`
  resolve natively on macOS/Linux (RFC 6761).