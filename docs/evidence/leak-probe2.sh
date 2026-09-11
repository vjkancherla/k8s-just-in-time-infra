#!/usr/bin/env bash
# Probe v2: does a claim whose destroy succeeds on the resync *retry* leak its IP block?
#
# v1 failed to test this: it restarted the runner as soon as the phase went Deleting, and the
# sweep's in-flight destroy then succeeded (09:39:26 -> 09:39:36), so the sweep released the
# block itself (main.py line 896) and the guard correctly skipped the handler's release.
#
# This version keeps the runner down until the first attempt AND at least two retries have
# failed, so the success definitely comes from the retry branch (line 844-849), which calls
# remove_finalizer_and_delete() and never calls release_block(). The delete handler then sees
# phase == "Deleting" (proved by the v1 log) and skips its release too - so nothing releases.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra
NS=hatch-leak
L=/tmp/leak-probe2.log
: > "$L"
log() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$L"; }
ledger() { kubectl get cm jit-ipam -n default -o jsonpath='{.data.allocations}'; }
phase() { kubectl get infraclaim "$NS-redis" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "<gone>"; }
logs() { kubectl -n default logs deploy/jit-controller --tail=200 2>/dev/null | grep "hatch-leak-redis" | tail -3; }

# Clean this namespace only.
kubectl patch infraclaim "$NS-redis" -n "$NS" --type=json \
  -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null 2>&1 || true
kubectl delete ns "$NS" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
kubectl get ns "$NS" -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
  | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null 2>&1 || true
docker rm -f "$NS-redis-redis" >/dev/null 2>&1 || true

log "ledger before: $(ledger)"
kubectl create ns "$NS" >/dev/null 2>&1 || true
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
log "claim is $(phase); ledger: $(ledger)"

kubectl delete deployment probe-vote -n "$NS" --wait=true >/dev/null 2>&1
for _ in $(seq 1 40); do
  [[ "$(phase)" == "Orphaned" ]] && break
  sleep 3
done
log "claim is $(phase) after deleting the Deployment"

# Runner down, and it stays down until the retry path is unambiguously the one that succeeds.
docker stop jit-runner >/dev/null 2>&1
log "runner stopped"
for _ in $(seq 1 60); do
  [[ "$(phase)" == "Deleting" ]] && break
  sleep 3
done
log "claim is $(phase) after the TTL expired with the runner down; holding it down 120s more"
log "    controller says: $(logs | tr '\n' '|')"
sleep 120
log "still down; controller says: $(logs | tr '\n' '|')"

docker start jit-runner >/dev/null 2>&1
for _ in $(seq 1 60); do
  curl -fsS http://127.0.0.1:8100/health >/dev/null 2>&1 && break
  sleep 2
done
log "runner restarted; waiting for the retry to complete the destroy"
for _ in $(seq 1 80); do
  [[ "$(kubectl get infraclaim "$NS-redis" -n "$NS" >/dev/null 2>&1 && echo present || echo gone)" == "gone" ]] && break
  sleep 3
done
sleep 10

log "claim present: $(kubectl get infraclaim "$NS-redis" -n "$NS" >/dev/null 2>&1 && echo yes || echo no)"
log "container present: $(docker container inspect "$NS-redis-redis" >/dev/null 2>&1 && echo yes || echo no)"
log "controller says: $(logs | tr '\n' '|')"
log "LEDGER AFTER: $(ledger)"
log "VERDICT: claim and container are gone; if the ledger still names $NS, the retry path leaked the block"
log done
