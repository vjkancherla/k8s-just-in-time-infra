#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

TEST_NS="s12-test"
CLAIM_NAME="${TEST_NS}-redis"
MODULE="redis"
DEPLOY_NAME="s12-deploy"
ANNOTATION='{"module":"redis","moduleVersion":"v1","params":{},"softDeleteTTL":"2m"}'

cleanup() {
  # Restore controller to 1 replica if scaled down
  kubectl scale deployment/jit-controller -n default --replicas=1 2>/dev/null || true
  kubectl rollout status deployment/jit-controller -n default --timeout=120s 2>/dev/null || true
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

echo "PASS: claim is Ready"

# --- Step 2: Scale controller to 0 (simulate controller down) ---

kubectl scale deployment/jit-controller -n default --replicas=0
sleep 5  # wait for pod to terminate

CONTROLLER_PODS=$(kubectl get pods -n default -l app=jit-controller --no-headers 2>/dev/null | wc -l | tr -d ' ')
[[ "$CONTROLLER_PODS" == "0" ]] || fail "controller should have 0 pods, got $CONTROLLER_PODS"

echo "PASS: controller scaled to 0"

# --- Step 3: Delete the Deployment while controller is down ---

kubectl delete deployment "$DEPLOY_NAME" -n "$TEST_NS" --ignore-not-found

# Verify Deployment is gone but claim is still Ready (no controller to notice)
sleep 3
PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
[[ "$PHASE" == "Ready" ]] || fail "claim should still be Ready with controller down, phase=$PHASE"

echo "PASS: Deployment deleted, claim still Ready (controller was down)"

# --- Step 4: Scale controller back to 1 ---

kubectl scale deployment/jit-controller -n default --replicas=1
kubectl rollout status deployment/jit-controller -n default --timeout=120s

echo "PASS: controller scaled back to 1"

# --- Step 5: Within one resync interval the claim is Orphaned ---
# Resync runs every 30s with initial_delay=True. Allow up to 90s for the
# controller to start, run its first resync tick, and patch the claim.

for _ in $(seq 1 90); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Orphaned" ]] && break
  sleep 1
done
[[ "$PHASE" == "Orphaned" ]] || fail "claim should be Orphaned after controller restart, phase=$PHASE"

EXPIRES=$(kubectl get infraclaim "$CLAIM_NAME" -n "$TEST_NS" -o jsonpath='{.status.expiresAt}' 2>/dev/null || echo "")
[[ -n "$EXPIRES" && "$EXPIRES" != "null" ]] || fail "expiresAt should be set when Orphaned, got: '$EXPIRES'"

echo "PASS: claim is Orphaned with expiresAt after controller restart"
echo "PASS: S12 controller restart resilience verified"
