# Manual Guide — JIT Infra PoC

> Drive the whole thing by hand, one command at a time, watching each piece appear. This
> is the fastest way to get reacquainted after time away: the `make` targets hide exactly
> the steps you need to see.
>
> 👉 For the short version, see [`JIT-MAKEFILE-GUIDE.md`](JIT-MAKEFILE-GUIDE.md). For the
> app's own R1–R17 walkthrough, see
> [`app/docs/MANUAL-TESTING-GUIDE.md`](../app/docs/MANUAL-TESTING-GUIDE.md). The design this
> implements is [`jit-infra-poc.md`](jit-infra-poc.md); the diagrams are
> [`jit-infra-flows.md`](jit-infra-flows.md).

**On names:** where a resource name could have changed, this guide shows you the command
that *finds* it rather than asserting what it is. If a snippet here disagrees with your
cluster, trust the cluster and fix the guide.

---

## Table of Contents

1. [What this thing actually is](#1-what-this-thing-actually-is)
2. [Prerequisites](#2-prerequisites)
3. [Bring it up, a piece at a time](#3-bring-it-up-a-piece-at-a-time)
4. [Watch a claim get created](#4-watch-a-claim-get-created)
5. [The readiness gate](#5-the-readiness-gate)
6. [Prove the app reaches its infrastructure](#6-prove-the-app-reaches-its-infrastructure)
7. [Soft delete: the clock](#7-soft-delete-the-clock)
8. [Resurrection](#8-resurrection)
9. [Refcounting](#9-refcounting)
10. [Hard delete: the namespace](#10-hard-delete-the-namespace)
11. [Controller restart](#11-controller-restart)
12. [The ledger and the state store](#12-the-ledger-and-the-state-store)
13. [Talking to the runner directly](#13-talking-to-the-runner-directly)
14. [Teardown](#14-teardown)
15. [When something is wrong](#15-when-something-is-wrong)

---

## 1. What this thing actually is

A tenant annotates a Deployment. A controller notices, creates a claim, asks a runner to
provision a real container outside the cluster, and wires it back in as a Secret, a
Service and an EndpointSlice. When nothing references it any more, a clock starts.

```
Deployment (annotation)
      │  watched by
      ▼
jit-controller ──HTTP──► jit-runner ──tofu apply──► docker container
   (in cluster,           (on the docker            (172.19.0.10x)
    namespace default)     network, .10)
      │
      └──► InfraClaim (owned by the Namespace, holds a finalizer)
           Secret + Service + EndpointSlice  ◄── pods reach the container through these
```

Two planes, split on purpose: **the controller never touches Docker and never holds state
credentials.** That separation is the point of the shape, and it is the thing to
re-notice when you come back.

| Piece | Where | Why it is there |
|---|---|---|
| `jit-controller` | in the cluster, `default` | Watches annotations, owns claim lifecycle |
| `jit-ipam` ConfigMap | in the cluster, `default` | The address ledger, a block of ten per namespace |
| `jit-runner` | docker network, `172.19.0.10` | Holds the docker socket, runs OpenTofu |
| MinIO | docker network, `172.19.0.11` | OpenTofu state, bucket `jit-state` |
| the infra | docker network, `.100`+ | Redis, Postgres, pgAdmin — one block per namespace |

**Tenants never run in `default`.** The demo lives in `voting-a` and `voting-b`; `default`
holds the control plane. The app's Makefile defaults `NS` to the `voting-a` overlay so a
bare `make all` cannot land in the wrong place.

---

## 2. Prerequisites

| Tool | Check |
|------|-------|
| Docker | `docker --version` |
| k3d | `k3d version` |
| kubectl | `kubectl version --client` |
| jq | `jq --version` |
| OpenTofu | `tofu version` (used inside the runner container, handy on the host too) |

The whole stack assumes the Docker network `k3d-voting-app` on `172.19.0.0/16`. That
subnet is not the default — it is passed at cluster creation, and nothing works without
it.

> **macOS:** the host cannot route to `172.19.0.x`. You can inspect those containers with
> `docker exec` and `docker inspect`, but you cannot `curl` them from your terminal. This
> is normal and is why the checks all go through `docker exec` or through a pod.

---

## 3. Bring it up, a piece at a time

### 3.1 Cluster

```bash
k3d cluster list                      # is one already there?
cd app && ./scripts/deploy.sh         # creates the cluster if missing, with the subnet
```

Confirm the network is what everything else assumes:

```bash
docker network inspect k3d-voting-app -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

✅ **Pass:** `172.19.0.0/16`.

### 3.2 The JIT plane

```bash
./scripts/jit-up.sh
```

Then look at what it made, in the order it made it:

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep jit
docker inspect jit-minio  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
docker inspect jit-runner -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

✅ **Pass:** MinIO on `.11`, the runner on `.10`, both running.

```bash
kubectl get crd | grep infraclaim
kubectl get deploy -n default
kubectl logs deploy/jit-controller -n default --tail=20
```

✅ **Pass:** the CRD is registered and the controller is `1/1` with a resync line in its
log.

> **Why this order:** the controller calls the runner, the runner writes to MinIO. Start
> them backwards and the controller logs connection errors until the others catch up.

---

## 4. Watch a claim get created

Deploy the app into a tenant namespace and watch the claim appear:

```bash
kubectl get infraclaims -A -w &        # leave this running
cd app && make all NS=voting-a
```

Then stop the watch and look properly:

```bash
kubectl get infraclaims -A
kubectl get infraclaims -n voting-a -o yaml | head -60
```

What to look at in that YAML, in order of how much it tells you:

| Field | What it means |
|---|---|
| `metadata.ownerReferences` | Points at the **Namespace**, not the Deployment. This is why the claim survives Deployment churn and dies with the namespace |
| `metadata.finalizers` | Why a namespace stays `Terminating` if the runner call fails |
| `status.phase` | `Pending` → `Ready` → `Orphaned` → `Deleting` |
| `status.referencedBy` | Recomputed every resync, not maintained incrementally. This is what makes refcounting work without a counter |
| `status.expiresAt` | Only set while `Orphaned` |
| `status.address` | The address the Service points at |

Find the annotation that started it all:

```bash
kubectl get deploy -n voting-a -o json \
  | jq -r '.items[] | {name: .metadata.name, annotations: .metadata.annotations}'
```

✅ **Pass:** at least one Deployment carries a `jit.infra/...` annotation, and there is a
claim for each distinct module named in them.

> The annotation is on the **Deployment**, never the Namespace — tenants cannot edit
> namespaces, so an annotation there would not be theirs to set.

---

## 5. The readiness gate

This is the part most designs skip, and it is worth seeing once.

There is no explicit "wait for infrastructure" step anywhere. The pod cannot start
because the Secret does not exist yet, and the kubelet holds it in
`CreateContainerConfigError` until it does. The absence *is* the gate.

To watch it, delete a Secret the controller created and bounce the pod:

```bash
kubectl get secrets -n voting-a
kubectl delete secret <the-jit-created-one> -n voting-a
kubectl delete pod -l app.kubernetes.io/component=worker -n voting-a
kubectl get pods -n voting-a -w
```

✅ **Pass:** the pod sits in `CreateContainerConfigError`, then starts by itself once the
controller recreates the Secret on the next resync.

And the wiring that makes an out-of-cluster container reachable by Service name:

```bash
kubectl get svc,endpointslice -n voting-a
kubectl get endpointslice -n voting-a -o json \
  | jq '.items[] | {name: .metadata.name, addresses: [.endpoints[].addresses[]]}'
```

✅ **Pass:** the Service has **no selector**, and the EndpointSlice holds a `172.19.0.10x`
address. That is the whole trick — a normal Service name resolving to something
Kubernetes does not manage.

---

## 6. Prove the app reaches its infrastructure

From inside a pod, not from your laptop:

```bash
POD=$(kubectl get pod -n voting-a -l app.kubernetes.io/component=worker -o name | head -1)
kubectl exec -n voting-a $POD -- python -c "
import socket,os
for host in ('redis','postgres'):
    try:
        print(host, socket.gethostbyname(host))
    except Exception as e:
        print(host, 'FAILED', e)
"
```

✅ **Pass:** each name resolves to a `172.19.0.10x` address.

Then the app end to end. The Ingress hosts and ports come from the cluster:

```bash
kubectl get ingress -A -o json \
  | jq -r '.items[] | .metadata.namespace + "  " + (.spec.rules[].host) +
           "  tls=" + ((.spec.tls // []) | length | tostring)'
docker port $(docker ps --filter name=serverlb --format '{{.Names}}')
```

Open the vote page in a browser (self-signed certificate — accept the warning), vote, and
watch the result page. Or check the tally directly in the container the runner created:

```bash
PG=$(docker ps --format '{{.Names}}' | grep postgres | head -1)
docker exec $PG psql -U postgres -d voting -t -A -c 'SELECT choice, COUNT(*) FROM votes GROUP BY choice'
```

✅ **Pass:** votes cast through the Ingress appear in a Postgres that is not in the
cluster at all.

> The database is `voting`. `votingdb` is a never-populated placeholder — if you are
> querying it and seeing nothing, that is why.

---

## 7. Soft delete: the clock

Note the container id first, because the whole point is that it does not change:

```bash
docker ps --format '{{.ID}}  {{.Names}}' | grep voting-a
kubectl delete deployment voting-app-vote -n voting-a
```

Now wait for a resync tick (30s) and watch the claim, not the pod:

```bash
watch -n2 'kubectl get infraclaims -n voting-a -o custom-columns=\
NAME:.metadata.name,PHASE:.status.phase,REFS:.status.referencedBy,EXPIRES:.status.expiresAt'
```

✅ **Pass:** the claim goes `Ready` → `Orphaned`, `expiresAt` is set to roughly now plus
the TTL, and:

```bash
docker ps --format '{{.ID}}  {{.Names}}' | grep voting-a
```

✅ **Pass:** the containers are **still running**, with the same ids. Nothing was
destroyed. A deleted Deployment starts a clock; it does not delete infrastructure.

If you want to watch the clock actually run out, set a short TTL — the J-suite runs with
two minutes for exactly this reason.

---

## 8. Resurrection

Inside the window, put the Deployment back:

```bash
kubectl apply -k app/kustomize/overlays/voting-a
```

✅ **Pass:** after a resync, `phase` is `Ready`, `expiresAt` is cleared, the container id
is unchanged, and the vote tally is exactly what it was. Nothing was reprovisioned.

This is the transition the design exists for: a rollout, a `kubectl delete` and re-apply,
a CI redeploy — all of them cost nothing.

---

## 9. Refcounting

Two Deployments asking for Redis produce one claim, and it only orphans when the last one
goes. There is no counter anywhere — `referencedBy` is recomputed from scratch on every
pass, which is what makes it correct.

```bash
kubectl get infraclaims -n voting-a -o json \
  | jq '.items[] | {claim: .metadata.name, refs: .status.referencedBy}'
kubectl delete deployment voting-app-vote -n voting-a
# wait one resync
kubectl get infraclaims -n voting-a -o json \
  | jq '.items[] | {claim: .metadata.name, phase: .status.phase, refs: .status.referencedBy}'
```

✅ **Pass:** the Redis claim stays `Ready` because `worker` still references it, while the
claims only `vote` referenced go `Orphaned`.

---

## 10. Hard delete: the namespace

```bash
kubectl delete ns voting-b &
kubectl get ns voting-b -w
```

In another terminal:

```bash
kubectl logs -f deploy/jit-controller -n default
docker ps --format '{{.Names}}' | grep voting-
```

✅ **Pass:** all of `voting-b`'s containers are destroyed **at once**, `expiresAt` is
ignored entirely, and `voting-a` is untouched.

Deleting a namespace is deliberate in a way that deleting a Deployment is not, so the two
paths converge on the same destroy at different speeds. The finalizer is what makes this
safe: if the runner call fails, the finalizer is not released and the namespace sits in
`Terminating` rather than losing track of a container.

**Escape hatch** if that happens. First find out which claim is stuck, and why:

```bash
kubectl get infraclaims -n voting-b -o yaml
```

Then destroy the infrastructure by hand. `tofu` needs the same backend the runner uses, so the
credentials come from `deploy/.env`:

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
./scripts/jit-down.sh
```

---

## 11. Controller restart

Events are missed when a controller restarts. The watch makes the common case fast; the
resync makes it correct. Prove it by removing the watch from the equation:

```bash
kubectl delete pod -l app=jit-controller -n default    # controller is down
kubectl delete deployment voting-app-vote -n voting-a  # delete event happens with nobody listening
# wait for the controller to come back, then a resync tick
kubectl get infraclaims -n voting-a
```

✅ **Pass:** the claim still goes `Orphaned`. The controller never saw the delete event —
it worked it out by listing Deployments and finding no references.

The clock starts late rather than early, which is the safe direction to be wrong in.

---

## 12. The ledger and the state store

**Addresses.** A block of ten per namespace, from `.100`:

```bash
kubectl get cm jit-ipam -n default -o yaml
```

✅ **Pass:** one entry per namespace, blocks that do not overlap. The read-pick-patch is
serialised per namespace — an earlier version of this raced and handed two claims the
same address.

**OpenTofu state.** One object per namespace and module:

```bash
docker exec jit-minio find /data/jit-state -name xl.meta | sed 's|/xl.meta||'
```

✅ **Pass:** keys shaped `ns/<namespace>/<module>`. Nothing outside that prefix, and
nothing left behind for a namespace that is gone.

---

## 13. Talking to the runner directly

Only useful when you suspect the controller and the runner disagree. The runner is on the
Docker network, so this has to come from inside it:

```bash
docker exec jit-runner env | grep -i token     # the bearer the controller uses
docker exec jit-runner curl -s localhost:8080/v1/runs -H "Authorization: Bearer $TOKEN"
```

The API is small: `POST /v1/runs` with module, version, workspace and params; `DELETE
/v1/runs/{workspace}` to destroy. Both are idempotent — creating twice is a no-op, and
that is asserted by a checkpoint.

> Check the exact request shape in `jit-runner/main.py` before hand-crafting one; it is
> the piece most likely to have moved since this guide was written.

---

## 14. Teardown

```bash
./scripts/jit-down.sh          # plane only; cluster and app survive
```

Then confirm nothing was left behind:

```bash
docker ps -a --format '{{.Names}}' | grep -E 'jit|voting-'
docker volume ls | grep -E 'jit|voting-'
```

✅ **Pass:** neither command returns anything.

**A container removal takes its volume.** A Postgres data directory carries its own
password, so a volume outliving its container makes the next stack's fresh password
unusable — and the failure looks like an authentication bug rather than a leftover.

Everything, cluster included:

```bash
./scripts/jit-down.sh && (cd app && make destroy)
k3d cluster list
```

---

## 15. When something is wrong

| Symptom | Where to look |
|---|---|
| Pod stuck in `CreateContainerConfigError` | `kubectl get infraclaims -A` — the claim is not Ready. Then the controller log |
| Claim stuck in `Pending` | The controller could not reach the runner, or tofu failed. `docker logs jit-runner` |
| Claim stuck in `Failed` | The runner returned an error; it retries with backoff. The runner log has the tofu output |
| Namespace stuck `Terminating` | A finalizer is held. §10's escape hatch |
| Two claims, same address | The ledger, §12 |
| App cannot resolve `redis` | The EndpointSlice, §5. A Service with a selector would also break this |
| Fresh Postgres rejects its password | A volume outlived its container. §14 |
| Everything looks right but the app is empty | Wrong database — it is `voting`, not `votingdb` |

**The order to check things in:** claim phase → controller log → runner log → the
container itself. Three of those four are one `kubectl` or `docker logs` away, and the
phase alone usually tells you which of the others to open.

---

## Quick Reference

| Goal | Command |
|------|---------|
| What claims exist | `kubectl get infraclaims -A` |
| Why a claim is in that phase | `kubectl get infraclaims -n <ns> -o yaml` |
| What the controller is doing | `kubectl logs -f deploy/jit-controller -n default` |
| What the runner did | `docker logs jit-runner` |
| What is actually running | `docker ps --format '{{.Names}}\t{{.Status}}'` |
| The address ledger | `kubectl get cm jit-ipam -n default -o yaml` |
| The state objects | `docker exec jit-minio find /data/jit-state -name xl.meta` |
| All of the above, as JSON | `make state \| python3 -m json.tool` |

**Tip:** `make state` returns everything on this page in one object — it is built from
exactly these commands. When the console looks wrong, run the command rather than
debugging the page.
