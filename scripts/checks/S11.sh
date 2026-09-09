#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

TEST_NS="s11-test"
CLAIM_NAME="${TEST_NS}-redis"
MODULE="redis"
DEPLOY_NAME="s11-deploy"
ANNOTATION='{"module":"redis","moduleVersion":"v1","params":{},"softDeleteTTL":"30d"}'

cleanup() {
  # Remove test namespace (if still exists)
  kubectl delete ns "$TEST_NS" --ignore-not-found 2>/dev/null || true
  # Restore controller WATCH_NAMESPACES to default
  kubectl set env deployment/jit-controller -n default WATCH_NAMESPACES=default 2>/dev/null || true
  kubectl rollout status deployment/jit-controller -n default --timeout=120s 2>/dev/null || true
}
trap cleanup EXIT

# --- Setup: configure controller to watch test namespace ---

kubectl set env deployment/jit-controller -n default "WATCH_NAMESPACES=default,${TEST_NS}" 2>/dev/null
kubectl rollout status deployment/jit-controller -n default --timeout=120s
sleep 3  # let controller establish watches

# --- Clean slate ---

kubectl delete ns "$TEST_NS" --ignore-not-found 2>/dev/null || true
sleep 2

# --- Step 1: Create namespace, Deployment, wait for Ready ---

kubectl create ns "$TEST_NS"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $TEST_NS
  annotations:
    jit.infra/redis: '$ANNOTATION'
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_NAME
  template:
    metadata:
      labels:
        app: $DEPLOY_NAME
    spec:
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.5
EOF

for _ in $(seq 1 60); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Ready" ]] && break
  sleep 2
done
[[ "$PHASE" == "Ready" ]] || fail "claim did not reach Ready, phase=$PHASE"

# --- Step 2: Delete Deployment → Orphaned with long TTL ---

kubectl delete deployment "$DEPLOY_NAME" -n "$TEST_NS" --ignore-not-found

for _ in $(seq 1 65); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Orphaned" ]] && break
  sleep 1
done
[[ "$PHASE" == "Orphaned" ]] || fail "claim should be Orphaned, phase=$PHASE"

kubectl get infraclaim "$CLAIM_NAME" -n "$TEST_NS" -o jsonpath='{.status.expiresAt}' 2>/dev/null | grep -q . \
  || fail "expiresAt should be set"

kubectl get secret "jit-${MODULE}" -n "$TEST_NS" >/dev/null 2>&1 \
  || fail "Secret jit-${MODULE} should exist when Orphaned"

echo "PASS: Orphaned with 30d TTL, Secret present"

# --- Step 3: Delete namespace → immediate teardown ---

kubectl delete ns "$TEST_NS"

# Verify namespace is gone within 60s (should be much faster)
for _ in $(seq 1 60); do
  if ! kubectl get ns "$TEST_NS" >/dev/null 2>&1; then
    NS_GONE=true
    break
  fi
  sleep 1
done
[[ "${NS_GONE:-false}" == "true" ]] || fail "namespace stuck in Terminating"

echo "PASS: namespace deleted without hanging"

if kubectl get infraclaim "$CLAIM_NAME" -n "$TEST_NS" >/dev/null 2>&1; then
  fail "claim should be gone after namespace deletion"
fi

if kubectl get secret "jit-${MODULE}" -n "$TEST_NS" >/dev/null 2>&1; then
  fail "Secret jit-${MODULE} should be gone after namespace deletion"
fi

echo "PASS: claim and Secret destroyed before TTL expiry"
echo "PASS: S11 hard delete verified"
