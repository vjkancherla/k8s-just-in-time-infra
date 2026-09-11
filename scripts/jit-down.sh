#!/usr/bin/env bash
set -euo pipefail

# scripts/jit-down.sh - tear the JIT stack down.
#
#   make jit-down   ->   remove the controller, the runner, MinIO, and any
#                        leftover JIT containers and the volumes they own
#
# Order is load-bearing. The claims are torn down *first*, while the runner is
# still up, so the containers they own are destroyed properly rather than left
# behind; only then do the runner and the controller go away. Anything the
# destroy missed is removed by name at the end, together with the volume that
# container owns - a Postgres data directory carries its password inside itself,
# so a container-less volume is what breaks the next stack's authentication. The
# claims are also *waited* for: their deletion is asynchronous, the controller
# owns a finalizer on them, and a stack that comes down mid-destroy leaves them
# Terminating (see the note at step 1 - they return as Ready with no container
# behind them and block the tenant's recovery).
#
# The CRD is deliberately NOT deleted: it is cheap to re-apply, and leaving it
# means the claim objects (and their history) survive a stack bounce. `make
# jit-up` re-applies it anyway.
#
# The IPAM ledger IS removed. `jit-ipam` is created and patched only by the
# controller, so it is not in deploy/controller.yaml and the delete below never
# sees it; a ledger outliving the claims it counted makes a namespace's count
# drift permanently upward, so its block is never freed and the address range
# shrinks by ten per bounced stack. Every claim is destroyed first, so an empty
# ledger is the truthful state. (S17 review, `docs/reviews/S17-findings.md` 1.)
#
# This removes the stack, not the tenants. A namespace that still runs the voting
# app keeps its Deployments; their pods stay in Init because the jit-redis /
# jit-postgres Services the controller wrote are gone with it. What does *not*
# survive is the module data: a real destroy has always taken the postgres volume
# with its container (J6 records "postgres data volume removed"), and step 2 now
# takes it too when the destroy could not run.
#
# Their claims are gone too, and `make jit-up` will not recreate them on its own:
# kopf does not replay on.create for objects that already existed, and an unchanged
# `kubectl apply` produces no event for the controller to see. Touch the annotated
# Deployment to bring a tenant back -
#
#   kubectl rollout restart deployment/<name> -n <ns>
#
# - which re-creates the claims and re-provisions from the MinIO state. Verified by
# running the full bounce (jit-down, jit-up, touch, three claims Ready again).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CTRL_NS="default"
fail() { echo "FAIL: $1"; exit 1; }

# The CRD may not exist at all (a cold host, or a bounce in progress), and under
# `set -euo pipefail` a kubectl that fails inside a command substitution takes the whole
# script down with it - which is how this bit the first cold run: `jit-down` exited 1 on
# a cluster with no InfraClaims to list, and left the module containers behind.
claims_left() { (kubectl get infraclaims -A -o name 2>/dev/null || true) | wc -l | tr -d ' '; }

command -v docker >/dev/null 2>&1 || fail "'docker' is not on PATH"
command -v kubectl >/dev/null 2>&1 || fail "'kubectl' is not on PATH"

# 1. InfraClaims. Drop the finalizer first: a live claim holds its namespace in
#    Terminating, and the delete handler refuses to run until the finalizer it
#    owns has been seen. Removing it lets the delete proceed, and the handler
#    still destroys the infra on its way out.
claims="$(kubectl get infraclaims -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [[ -n "$claims" ]]; then
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    ns="${ref%%/*}"; name="${ref##*/}"
    kubectl patch infraclaim "$name" -n "$ns" --type=json \
      -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null 2>&1 || true
    kubectl delete infraclaim "$name" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done <<< "$claims"
  echo "removed $(printf '%s\n' "$claims" | wc -l | tr -d ' ') InfraClaim(s)"
else
  echo "no InfraClaims to remove"
fi

# The deletes above are asynchronous: the controller destroys the infra and holds a
# finalizer of its own, so the objects outlive the command. Wait for them to actually
# go before the runner does - that is the whole point of deleting them first. Without
# this wait the stack comes down mid-destroy and the claims are left Terminating; they
# come back as *Ready* on the next `make jit-up` with no container behind them, and
# since Ready is what the controller checks, the tenant is never re-provisioned and its
# pods never start. Found by running the bounce twice, the second time failing
# (docs/evidence/s17-jitdown-bounce.sh, and the run it caught in
# docs/evidence/s17-jitdown-bounce-race.log).
for _ in $(seq 1 90); do
  [[ "$(claims_left)" == "0" ]] && break
  sleep 2
done
remaining="$(claims_left)"
if [[ "$remaining" != "0" ]]; then
  echo "WARNING: $remaining InfraClaim(s) are still terminating. The controller finishes"
  echo "         them on the next 'make jit-up' - wait for them to go before touching a"
  echo "         Deployment to bring the tenant back, or its claims will look Ready with"
  echo "         nothing behind them."
else
  echo "InfraClaims gone; the infra they owned is destroyed"
fi

# 2. Leftover JIT containers, and the volumes they own. Module containers are named
#    "<ns>-<module>-<module>" (jit-modules/modules/*/main.tf), so the pattern is
#    exact - it cannot match an unrelated container that merely ends in "-redis".
#
#    The volume goes with the container, because a Postgres data directory carries
#    its password inside itself: Postgres ignores POSTGRES_PASSWORD on a data
#    directory that already exists, and this sweep runs precisely when no state and
#    no Secret are left to read the password from. Left behind, that volume is
#    reattached by the next stack, which writes a *new* password into jit-postgres -
#    the container comes up, the Secret is right, and the app can never authenticate
#    (`FATAL: password authentication failed for user "postgres"`, the cold-start
#    blocker recorded in docs/evidence/s17-cold-path.log). The primary path already
#    takes the volume: `tofu destroy` destroys the docker_volume with the container
#    (jit-modules/modules/postgres/main.tf), and J6 reports "postgres data volume
#    removed". This is the fallback sweep obeying the same rule.
#
#    The volume is "<container>-data": the module names it "<var.name>-postgres-data"
#    with var.name "<ns>-postgres". redis and pgadmin declare no volume at all, so
#    the inspect below is what keeps this from guessing.
leftovers="$(docker ps -a --format '{{.Names}}' \
  | grep -E -- '-(redis-redis|postgres-postgres|pgadmin-pgadmin)$' || true)"
if [[ -n "$leftovers" ]]; then
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    docker rm -f "$c" >/dev/null 2>&1 || true
    echo "removed leftover container $c"
    if docker volume inspect "${c}-data" >/dev/null 2>&1; then
      docker volume rm -f "${c}-data" >/dev/null 2>&1 || true
      echo "removed leftover volume ${c}-data"
    fi
  done <<< "$leftovers"
fi

# 3. Controller (Deployment, RBAC, token Secret, code ConfigMap).
kubectl delete -f deploy/controller.yaml --ignore-not-found >/dev/null 2>&1 || true
echo "removed the controller"

# 4. Runner, then MinIO.
./deploy/runner.sh down
docker rm -f minio >/dev/null 2>&1 || true
echo "removed the runner and MinIO"

# 5. The IPAM ledger. Every claim was destroyed above and the controller is gone, so
#    the truthful ledger is an empty one. It is not in deploy/controller.yaml - the
#    controller creates it on first allocation - which is why step 3 missed it.
kubectl delete configmap jit-ipam -n "$CTRL_NS" --ignore-not-found >/dev/null 2>&1 || true
echo "removed the IPAM ledger"

echo "PASS: jit stack down (the InfraClaim CRD is left in place and make jit-up re-applies it; the IPAM ledger is cleared)"
