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
3. **Replaced connection details** — the app consumes `REDIS_URL` and `DATABASE_URL`
   from the controller-written `jit-redis` / `jit-postgres` Secrets, so no infra
   hostname, port, database name, user or password is hardcoded in the manifests
   or application code.
4. **Preserved the verification** — R1-R17 still pass, now reading from JIT-provisioned
   infrastructure

## Deployment model

The app uses **Kustomize** with a base and per-namespace overlays:

```
app/kustomize/
├── base/                          # Shared manifests
│   ├── vote-deployment.yaml       # vote + JIT annotations (redis, postgres, pgadmin)
│   ├── worker-deployment.yaml     # worker + JIT annotation (redis only)
│   ├── result-deployment.yaml     # result + JIT annotation (postgres)
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

An annotation is a provisioning request **and** a keep-alive lease, not a list of the pod's
dependencies: the controller reads only Deployment metadata, and `status.referencedBy` is
recomputed from those annotations alone. Every Deployment that uses a module must therefore
name it, or the last-reference rule can destroy infrastructure a running pod is still using.

| Deployment | Annotates | Consumes |
|---|---|---|
| `vote` | `redis`, `pgadmin` | Redis (`REDIS_URL`). pgAdmin has no consumer — it is leased here as the demo's soft-delete subject, and it is the only module with a cross-module dependency |
| `worker` | `redis`, `postgres` | Redis (the queue) and Postgres (writes the `votes` table) |
| `result` | `postgres` | Postgres only |

```yaml
# vote
annotations:
  jit.infra/redis:   '{"module":"redis",  "moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'
  jit.infra/pgadmin: '{"module":"pgadmin","moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'

# worker
annotations:
  jit.infra/redis:    '{"module":"redis",   "moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'
  jit.infra/postgres: '{"module":"postgres","moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'

# result
annotations:
  jit.infra/postgres: '{"module":"postgres","moduleVersion":"v1", "params":{}, "softDeleteTTL":"10m"}'
```

`redis` is referenced by `vote` and `worker`; `postgres` by `worker` and `result`. The
controller's refcount rule keeps each claim `Ready` until the **last** referencing Deployment
is deleted (J7), so deleting `vote` orphans only `pgadmin` — the one module it leases alone —
and leaves the queue and the live database untouched.

`voting-b` overrides the pgadmin annotation to use a different host port (`5051` instead
of `5050`) because two pgAdmin containers cannot share the same host port.

For the full annotation-to-infrastructure mapping, see
[Annotation to State](annotation-to-state.md).

## How the app consumes JIT infrastructure

The controller writes three Kubernetes resources per module into the app's namespace:

| JIT creates | App reads | Purpose |
|---|---|---|
| `Secret jit-redis` | `REDIS_URL` env var (via `secretKeyRef` key `service_url`) | Full Redis connection URL |
| `Secret jit-postgres` | `DATABASE_URL` env var (via `secretKeyRef` key `service_url`) | Full Postgres connection URL |
| `Secret jit-postgres` | `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD` env vars (initContainer) | Postgres reachability check before app start |
| `Service jit-redis` | *(automatic, via `service_url`)* | In-cluster DNS to the container |
| `Service jit-postgres` | *(automatic, via `service_url`)* | In-cluster DNS to the container |
| `EndpointSlice jit-redis` | *(automatic)* | Routes Service traffic to the container's IP |
| `EndpointSlice jit-postgres` | *(automatic)* | Routes Service traffic to the container's IP |

The app never knows about Docker, IPAM, hostnames, ports, database names, or the runner. It reads Secrets and connects to
Services — exactly how it would consume infrastructure in a production cluster.

For the exact Secret name and every key each module Secret contains, see
[What each module Secret contains](annotation-to-state.md#what-each-module-secret-contains).

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