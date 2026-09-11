#!/usr/bin/env bash
# Repeat the J1 deploy from a clean slate and assert the 3 claims get 3 distinct IPs.
# Each iteration mirrors what verify-jit.sh's reset+J1 does, so a race shows up here.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra
A=voting-a
L=/tmp/race-test.log
: > "$L"
log() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$L"; }

clean_ns() {
  local ns="$1" ref
  for ref in $(kubectl get infraclaims -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    kubectl patch infraclaim "$ref" -n "$ns" --type=json -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null 2>&1
  done
  kubectl delete infraclaim -n "$ns" --all --ignore-not-found --wait=true >/dev/null 2>&1
  for m in redis postgres pgadmin; do docker rm -f "$ns-$m-$m" >/dev/null 2>&1; done
  docker volume rm -f "$ns-postgres-postgres-data" >/dev/null 2>&1
  kubectl delete ns "$ns" --ignore-not-found --timeout=120s >/dev/null 2>&1
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    kubectl get ns "$ns" -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
      | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1
  fi
}

for i in 1 2 3; do
  clean_ns "$A"
  kubectl patch cm jit-ipam -n default --type=merge -p '{"data":{"allocations":"{}"}}' >/dev/null 2>&1
  kubectl create ns "$A" >/dev/null 2>&1
  kubectl kustomize app/kustomize/overlays/$A | sed 's/"softDeleteTTL":"10m"/"softDeleteTTL":"2m"/g' | kubectl apply -f - >/dev/null
  for _ in $(seq 1 60); do
    [ "$(kubectl get infraclaims -n "$A" --no-headers 2>/dev/null | grep -c Ready)" = "3" ] && break
    sleep 3
  done
  ips="$(kubectl get infraclaims -n "$A" -o jsonpath='{range .items[*]}{.metadata.name}={.status.allocatedIP} {end}' 2>/dev/null)"
  distinct="$(kubectl get infraclaims -n "$A" -o jsonpath='{range .items[*]}{.status.allocatedIP}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
  uniq="$(kubectl get infraclaims -n "$A" -o jsonpath='{range .items[*]}{.status.allocatedIP}{"\n"}{end}' 2>/dev/null | sort -u | grep -c . || true)"
  phases="$(kubectl get infraclaims -n "$A" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase} {end}' 2>/dev/null)"
  if [ "$distinct" = "3" ] && [ "$uniq" = "3" ] && [ "$phases" = "voting-a-pgadmin:Ready voting-a-postgres:Ready voting-a-redis:Ready " ]; then
    log "iteration $i OK  ips=[$ips] ledger=$(kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}')"
  else
    log "iteration $i BAD ips=[$ips] distinct=$distinct uniq=$uniq phases=[$phases]"
    log "    ledger=$(kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}')"
  fi
done
clean_ns "$A"
log "done"
