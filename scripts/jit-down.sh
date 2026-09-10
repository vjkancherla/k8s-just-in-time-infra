#!/usr/bin/env bash
set -euo pipefail

# scripts/jit-down.sh - tear the JIT stack down.
#
#   make jit-down   ->   remove the controller, the runner, MinIO, and any
#                        leftover JIT containers
#
# Order is load-bearing. The claims are torn down *first*, while the runner is
# still up, so the containers they own are destroyed properly rather than left
# behind; only then do the runner and the controller go away. Anything the
# destroy missed is removed by name at the end.
#
# The CRD is deliberately NOT deleted: it is cheap to re-apply, and leaving it
# means the claim objects (and their history) survive a stack bounce. `make
# jit-up` re-applies it anyway.
#
# This removes the stack, not the tenants. A namespace that still runs the voting
# app keeps its Deployments; their pods stay in Init because the jit-redis /
# jit-postgres Services the controller wrote are gone with it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CTRL_NS="default"
fail() { echo "FAIL: $1"; exit 1; }

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

# 2. Leftover JIT containers. Module containers are named "<ns>-<module>-<module>"
#    (jit-modules/modules/*/main.tf), so the pattern is exact - it cannot match an
#    unrelated container that merely ends in "-redis".
leftovers="$(docker ps -a --format '{{.Names}}' \
  | grep -E -- '-(redis-redis|postgres-postgres|pgadmin-pgadmin)$' || true)"
if [[ -n "$leftovers" ]]; then
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    docker rm -f "$c" >/dev/null 2>&1 || true
    echo "removed leftover container $c"
  done <<< "$leftovers"
fi

# 3. Controller (Deployment, RBAC, token Secret, code ConfigMap).
kubectl delete -f deploy/controller.yaml --ignore-not-found >/dev/null 2>&1 || true
echo "removed the controller"

# 4. Runner, then MinIO.
./deploy/runner.sh down
docker rm -f minio >/dev/null 2>&1 || true
echo "removed the runner and MinIO"

echo "PASS: jit stack down (the InfraClaim CRD is left in place; make jit-up re-applies it)"
