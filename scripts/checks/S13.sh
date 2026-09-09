#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

NS_A="s13-a"
NS_B="s13-b"
CM_NAME="jit-ipam"
CM_NS="default"
ANNOTATION='{"module":"redis","moduleVersion":"v1","params":{},"softDeleteTTL":"30s"}'

cleanup() {
  kubectl delete deployment s13-deploy-a -n "$NS_A" --ignore-not-found 2>/dev/null || true
  kubectl delete deployment s13-deploy-b -n "$NS_B" --ignore-not-found 2>/dev/null || true
  # Force-remove any stuck claims
  for ns in "$NS_A" "$NS_B"; do
    for ic in $(kubectl get infraclaims -n "$ns" -o name 2>/dev/null || true); do
      kubectl patch "$ic" -n "$ns" --type=json \
        -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null || true
      kubectl delete "$ic" -n "$ns" --ignore-not-found 2>/dev/null || true
    done
  done
  kubectl delete ns "$NS_A" --ignore-not-found 2>/dev/null || true
  kubectl delete ns "$NS_B" --ignore-not-found 2>/dev/null || true
  # Clear stale allocations from ConfigMap
  python3 -c "
import json, subprocess, sys
try:
    raw = subprocess.check_output(
        ['kubectl','get','configmap','$CM_NAME','-n','$CM_NS','-o','jsonpath={.data.allocations}'],
        stderr=subprocess.DEVNULL)
    allocs = json.loads(raw)
    for ns in ['$NS_A','$NS_B']:
        allocs.pop(ns, None)
    body = {'apiVersion':'v1','kind':'ConfigMap',
            'metadata':{'name':'$CM_NAME','namespace':'$CM_NS'},
            'data':{'allocations':json.dumps(allocs)}}
    subprocess.run(['kubectl','apply','-f','-'], input=json.dumps(body).encode(), check=False)
except Exception:
    pass
" 2>/dev/null || true
  kubectl set env deployment/jit-controller -n default WATCH_NAMESPACES=default 2>/dev/null || true
  kubectl rollout status deployment/jit-controller -n default --timeout=120s 2>/dev/null || true
}
trap cleanup EXIT

# ── Setup: configure controller to watch both test namespaces ────────────────

kubectl set env deployment/jit-controller -n default "WATCH_NAMESPACES=default,${NS_A},${NS_B}" 2>/dev/null
kubectl rollout status deployment/jit-controller -n default --timeout=120s
sleep 3

# ── Clean slate ──────────────────────────────────────────────────────────────

kubectl delete ns "$NS_A" --ignore-not-found 2>/dev/null || true
kubectl delete ns "$NS_B" --ignore-not-found 2>/dev/null || true
# Clear ConfigMap
python3 -c "
import json, subprocess
body = {'apiVersion':'v1','kind':'ConfigMap',
        'metadata':{'name':'$CM_NAME','namespace':'$CM_NS'},
        'data':{'allocations':'{}'}}
subprocess.run(['kubectl','apply','-f','-'], input=json.dumps(body).encode(), check=False)
" 2>/dev/null || true

# ── Helper: create namespace + annotated Deployment ──────────────────────────

make_ns_deploy() {
  local ns="$1" deploy="$2"
  kubectl create ns "$ns" 2>/dev/null || true
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deploy
  namespace: $ns
  annotations:
    jit.infra/redis: '$ANNOTATION'
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $deploy
  template:
    metadata:
      labels:
        app: $deploy
    spec:
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.5
EOF
}

wait_ready() {
  local ns="$1" claim="$2"
  for _ in $(seq 1 60); do
    PHASE=$(kubectl get infraclaim "$claim" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$PHASE" == "Ready" ]] && break
    sleep 2
  done
  [[ "$PHASE" == "Ready" ]] || fail "claim $claim did not reach Ready, phase=$PHASE"
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 1: Two namespaces get non-overlapping blocks
# ═════════════════════════════════════════════════════════════════════════════

make_ns_deploy "$NS_A" "s13-deploy-a"
make_ns_deploy "$NS_B" "s13-deploy-b"

wait_ready "$NS_A" "${NS_A}-redis"
wait_ready "$NS_B" "${NS_B}-redis"

ALLOCATIONS=$(kubectl get configmap "$CM_NAME" -n "$CM_NS" -o jsonpath='{.data.allocations}' 2>/dev/null || echo "{}")

BLOCK_A=$(echo "$ALLOCATIONS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$NS_A',{}).get('base_ip',''))")
BLOCK_B=$(echo "$ALLOCATIONS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$NS_B',{}).get('base_ip',''))")

[[ -n "$BLOCK_A" ]] || fail "namespace $NS_A has no allocated block"
[[ -n "$BLOCK_B" ]] || fail "namespace $NS_B has no allocated block"
[[ "$BLOCK_A" != "$BLOCK_B" ]] || fail "blocks overlap: $BLOCK_A == $BLOCK_B"

OCTET_A=$(echo "$BLOCK_A" | awk -F. '{print $4}')
OCTET_B=$(echo "$BLOCK_B" | awk -F. '{print $4}')
[[ "$OCTET_A" -ge 100 && "$OCTET_A" -le 190 ]] || fail "block A octet $OCTET_A out of range 100-190"
[[ "$OCTET_B" -ge 100 && "$OCTET_B" -le 190 ]] || fail "block B octet $OCTET_B out of range 100-190"

IP_A=$(kubectl get infraclaim "${NS_A}-redis" -n "$NS_A" -o jsonpath='{.status.allocatedIP}' 2>/dev/null || echo "")
IP_B=$(kubectl get infraclaim "${NS_B}-redis" -n "$NS_B" -o jsonpath='{.status.allocatedIP}' 2>/dev/null || echo "")
[[ "$IP_A" == "$BLOCK_A" ]] || fail "claim allocatedIP=$IP_A != block base_ip=$BLOCK_A"
[[ "$IP_B" == "$BLOCK_B" ]] || fail "claim allocatedIP=$IP_B != block base_ip=$BLOCK_B"

echo "PASS: two namespaces have non-overlapping blocks ($BLOCK_A, $BLOCK_B)"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 2: Deleting the last claim (via TTL sweep) frees its block
# ═════════════════════════════════════════════════════════════════════════════

kubectl delete deployment "s13-deploy-a" -n "$NS_A" --ignore-not-found

# Wait for claim to become Orphaned
for _ in $(seq 1 60); do
  PHASE=$(kubectl get infraclaim "${NS_A}-redis" -n "$NS_A" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Orphaned" ]] && break
  sleep 2
done
[[ "$PHASE" == "Orphaned" ]] || fail "claim should be Orphaned after deleting deploy, phase=$PHASE"

echo "PASS: claim is Orphaned after deleting Deployment"

# Wait for TTL sweep to destroy claim and free block (30s TTL + 30s resync + buffer)
for _ in $(seq 1 120); do
  if ! kubectl get infraclaim "${NS_A}-redis" -n "$NS_A" >/dev/null 2>&1; then
    CLAIM_GONE=true
    break
  fi
  sleep 1
done
[[ "${CLAIM_GONE:-false}" == "true" ]] || fail "claim should be gone after TTL sweep"

# Wait a bit for the ConfigMap to be updated
sleep 5

ALLOCATIONS_AFTER=$(kubectl get configmap "$CM_NAME" -n "$CM_NS" -o jsonpath='{.data.allocations}' 2>/dev/null || echo "{}")

BLOCK_A_AFTER=$(echo "$ALLOCATIONS_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$NS_A',{}).get('base_ip',''))")
BLOCK_B_AFTER=$(echo "$ALLOCATIONS_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$NS_B',{}).get('base_ip',''))")

[[ -z "$BLOCK_A_AFTER" ]] || fail "block for $NS_A should be freed after TTL sweep, still=$BLOCK_A_AFTER"
[[ "$BLOCK_B_AFTER" == "$BLOCK_B" ]] || fail "block for $NS_B unchanged, was=$BLOCK_B now=$BLOCK_B_AFTER"

echo "PASS: last claim destroyed freed its block; other namespace untouched"

# ═════════════════════════════════════════════════════════════════════════════
# Phase 3: Re-creating claim in the same namespace gets a block again
# ═════════════════════════════════════════════════════════════════════════════

make_ns_deploy "$NS_A" "s13-deploy-a"
wait_ready "$NS_A" "${NS_A}-redis"

ALLOCATIONS_RECREATE=$(kubectl get configmap "$CM_NAME" -n "$CM_NS" -o jsonpath='{.data.allocations}' 2>/dev/null || echo "{}")
BLOCK_A_RECREATE=$(echo "$ALLOCATIONS_RECREATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$NS_A',{}).get('base_ip',''))")

[[ -n "$BLOCK_A_RECREATE" ]] || fail "re-created namespace $NS_A did not get a block"

echo "PASS: re-created claim got block $BLOCK_A_RECREATE"
echo "PASS: S13 IPAM verified"
