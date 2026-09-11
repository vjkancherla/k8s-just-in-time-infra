#!/usr/bin/env bash
# Probe v3: the same scenario as v2, run against the S17 retry-path fix.
#
# v2 (leak-probe2.sh) proved the defect: a claim whose destroy finally succeeds on the resync
# *retry* branch left its IP block in the ledger, because the TTL path's release only runs when
# its own destroy succeeded and the delete handler skips phase Deleting.
#
# The fix: the retry branch releases the block, and both paths release only after
# remove_finalizer_and_delete() reports the claim is really gone. v3 must therefore end with a
# ledger that names only voting-a - the `LEDGER AFTER` line is the assertion.
#
# Identical to v2 apart from this header and the log path, so the two logs are comparable.
set -uo pipefail
cd /Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra
NS=hatch-leak
L=/tmp/leak-probe3.log
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
log "VERDICT: claim and container gone; the ledger must name voting-a only - any hatch-leak entry is the retry path leaking again"
log done
