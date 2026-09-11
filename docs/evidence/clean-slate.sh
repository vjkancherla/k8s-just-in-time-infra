#!/usr/bin/env bash
# Clean slate only (no deploy): claims, jit containers, volumes, demo namespaces,
# and the IPAM ledger. Run before a fresh suite run.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra
for ref in $(kubectl get infraclaims -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  ns="${ref%%/*}"; name="${ref##*/}"
  kubectl patch infraclaim "$name" -n "$ns" --type=json -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null 2>&1
  kubectl delete infraclaim "$name" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1
done
for c in $(docker ps -a --format '{{.Names}}' | grep -E -- '-(redis-redis|postgres-postgres|pgadmin-pgadmin)$'); do
  docker rm -f "$c" >/dev/null 2>&1
done
for v in $(docker volume ls --format '{{.Name}}' | grep -E -- '-postgres-postgres-data$'); do
  docker volume rm -f "$v" >/dev/null 2>&1
done
for n in voting-a voting-b; do
  kubectl delete ns "$n" --ignore-not-found --timeout=120s >/dev/null 2>&1
  if kubectl get ns "$n" >/dev/null 2>&1; then
    kubectl get ns "$n" -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
      | kubectl replace --raw "/api/v1/namespaces/$n/finalize" -f - >/dev/null 2>&1
  fi
done
kubectl patch cm jit-ipam -n default --type=merge -p '{"data":{"allocations":"{}"}}' >/dev/null 2>&1 || true
echo "clean slate: claims=$(kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' ') containers=[$(docker ps -a --format '{{.Names}}' | grep -E -- '-redis-redis|-postgres-postgres|-pgadmin-pgadmin' | tr '\n' ' ')] ipam=$(kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}') ns=[$(kubectl get ns -o name 2>/dev/null | grep -E 'voting-a|voting-b' | tr '\n' ' ')]"
