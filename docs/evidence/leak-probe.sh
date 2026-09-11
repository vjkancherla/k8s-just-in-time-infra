#!/usr/bin/env bash
# Probe: does a claim whose destroy succeeds on the resync *retry* leak its IP block?
#
# Path under test (jit-controller/main.py):
#   TTL expires -> phase=Deleting, destroy FAILS (runner down) -> no release   (line 896 not reached)
#   next tick   -> resync sees phase == Deleting -> retry destroy -> SUCCEEDS  (line 844-847)
#                  ... remove_finalizer_and_delete(), and NO release_block
#   the delete  -> handle_claim_delete sees phase == "Deleting" -> SKIPS release (line 942)
# so the namespace's ledger entry survives with no claims left to justify it.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra
NS=hatch-leak
L=/tmp/leak-probe.log
: > "$L"
log() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$L"; }
ledger() { kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}'; }
claims() { kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' '; }
phase() { kubectl get infraclaim "$NS-redis" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "<none>"; }

# Start clean for this namespace only.
kubectl patch infraclaim "$NS-redis" -n "$NS" --type=json \
  -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null 2>&1 || true
kubectl delete infraclaim "$NS-redis" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
docker rm -f "$NS-redis-redis" >/dev/null 2>&1 || true
kubectl delete ns "$NS" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
kubectl get ns "$NS" -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
  | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null 2>&1 || true

log "ledger before: $(ledger)"
kubectl create ns "$NS" >/dev/null 2>&1 || true

# One module only (redis) so the probe is fast and the ledger entry is unambiguous.
kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-vote
  namespace: $NS
  annotations:
    jit.infra/redis: '{"module":"redis","moduleVersion":"v1","softDeleteTTL":"2m"}'
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probe-vote
  template:
    metadata:
      labels:
        app: probe-vote
    spec:
      containers:
        - name: app
          image: busybox:latest
          command: ["sleep", "3600"]
YAML

for _ in $(seq 1 60); do
  [[ "$(phase)" == "Ready" ]] && break
  sleep 3
done
log "claim phase after deploy: $(phase)  ledger: $(ledger)"

# Orphan it, then take the runner away before the TTL expires so the FIRST sweep
# attempt fails.
kubectl delete deployment probe-vote -n "$NS" --wait=true >/dev/null 2>&1
for _ in $(seq 1 40); do
  [[ "$(phase)" == "Orphaned" ]] && break
  sleep 3
done
log "claim phase after deleting the Deployment: $(phase)"
docker stop jit-runner >/dev/null 2>&1
log "runner stopped; waiting past the 2m TTL for a sweep that must fail"

for _ in $(seq 1 90); do
  [[ "$(phase)" == "Deleting" ]] && break
  sleep 3
done
log "claim phase after the TTL expired with the runner down: $(phase)"
log "ledger at this point: $(ledger)"

docker start jit-runner >/dev/null 2>&1
for _ in $(seq 1 60); do
  curl -fsS http://127.0.0.1:8100/health >/dev/null 2>&1 && break
  sleep 2
done
log "runner restarted, waiting for the resync retry to finish the destroy"

for _ in $(seq 1 80); do
  [[ "$(kubectl get infraclaim "$NS-redis" -n "$NS" >/dev/null 2>&1 && echo present || echo gone)" == "gone" ]] && break
  sleep 3
done

log "claim present now? $(kubectl get infraclaim "$NS-redis" -n "$NS" >/dev/null 2>&1 && echo yes || echo no)"
log "container present now? $(docker container inspect "$NS-redis-redis" >/dev/null 2>&1 && echo yes || echo no)"
log "TOTAL CLAIMS IN CLUSTER: $(claims)"
log "LEDGER AFTER: $(ledger)"
log "VERDICT: if the ledger still names $NS with no claims left, the block leaked"
log done
