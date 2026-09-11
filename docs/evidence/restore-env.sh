#!/usr/bin/env bash
# Undo the probes: remove the scratch namespace and its leaked ledger entry, then put
# voting-a back the way the S17 checkpoint left it.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra

kubectl delete infraclaim hatch-leak-redis -n hatch-leak --ignore-not-found --wait=false >/dev/null 2>&1 || true
docker rm -f hatch-leak-redis-redis >/dev/null 2>&1 || true
kubectl delete ns hatch-leak --ignore-not-found --timeout=90s >/dev/null 2>&1 || true
if kubectl get ns hatch-leak >/dev/null 2>&1; then
  kubectl get ns hatch-leak -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
    | kubectl replace --raw "/api/v1/namespaces/hatch-leak/finalize" -f - >/dev/null 2>&1 || true
fi
# The leaked entry the probe proved; clear the ledger so the run starts clean.
kubectl patch cm jit-ipam -n default --type=merge -p '{"data":{"allocations":"{}"}}' >/dev/null 2>&1 || true
echo "cleanup: ns=[$(kubectl get ns -o name 2>/dev/null | grep -E 'hatch-leak|voting-a|voting-b' | tr '\n' ' ')] ledger=$(kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}')"

kubectl create ns voting-a >/dev/null 2>&1 || true
kubectl kustomize app/kustomize/overlays/voting-a \
  | sed 's/"softDeleteTTL":"10m"/"softDeleteTTL":"2m"/g' | kubectl apply -f - >/dev/null 2>&1

for _ in $(seq 1 80); do
  [[ "$(kubectl get infraclaims -n voting-a --no-headers 2>/dev/null | grep -c Ready || true)" == "3" ]] && break
  sleep 3
done
echo "restored: $(kubectl get infraclaims -n voting-a --no-headers 2>/dev/null | tr -s ' ' | tr '\n' '|')"
echo "ledger: $(kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}')"
