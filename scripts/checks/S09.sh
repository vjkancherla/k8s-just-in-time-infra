#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

NAMESPACE="default"
CLAIM_NAME="${NAMESPACE}-redis"
DEPLOY_A="s9-test-deploy-a"
DEPLOY_B="s9-test-deploy-b"
ANNOTATION='{"module":"redis","moduleVersion":"v1","params":{},"softDeleteTTL":"2m"}'

cleanup() {
  kubectl delete deployment "$DEPLOY_A" --ignore-not-found 2>/dev/null || true
  kubectl delete deployment "$DEPLOY_B" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

# Clean slate
kubectl delete deployment "$DEPLOY_A" --ignore-not-found 2>/dev/null || true
kubectl delete deployment "$DEPLOY_B" --ignore-not-found 2>/dev/null || true

# Wait for claim from S8 (may already exist in default namespace)
CLAIM_EXISTS=false
for _ in $(seq 1 10); do
  if kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    CLAIM_EXISTS=true
    break
  fi
  sleep 2
done

if [ "$CLAIM_EXISTS" = "false" ]; then
  # Create a Deployment with the annotation to trigger claim creation via the handler
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_A
  namespace: $NAMESPACE
  annotations:
    jit.infra/redis: '$ANNOTATION'
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_A
  template:
    metadata:
      labels:
        app: $DEPLOY_A
    spec:
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.5
EOF

  for _ in $(seq 1 30); do
    PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$PHASE" == "Ready" ]] && break
    sleep 2
  done
fi

kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || fail "claim $CLAIM_NAME not found"

# Phase must be Ready
PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[[ "$PHASE" == "Ready" ]] || fail "claim phase is $PHASE, expected Ready"

# Ensure DEPLOY_A exists (may have been created above or from previous run)
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_A
  namespace: $NAMESPACE
  annotations:
    jit.infra/redis: '$ANNOTATION'
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_A
  template:
    metadata:
      labels:
        app: $DEPLOY_A
    spec:
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.5
EOF

# Create second Deployment annotating redis
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_B
  namespace: $NAMESPACE
  annotations:
    jit.infra/redis: '$ANNOTATION'
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_B
  template:
    metadata:
      labels:
        app: $DEPLOY_B
    spec:
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.5
EOF

# Wait for resync (timer fires at 30s intervals with initial_delay=True)
# Claim may have been created a while ago, so the timer could fire soon.
# Wait up to 45s for referencedBy to populate with both names.
FOUND=""
for _ in $(seq 1 45); do
  REFS=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.referencedBy}' 2>/dev/null || echo "")
  if echo "$REFS" | grep -q "$DEPLOY_A" && echo "$REFS" | grep -q "$DEPLOY_B"; then
    FOUND="both"
    break
  fi
  sleep 1
done

[[ "$FOUND" == "both" ]] || fail "referencedBy should contain both $DEPLOY_A and $DEPLOY_B, got: $REFS"

# Phase must still be Ready (orphaning not implemented yet)
PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[[ "$PHASE" == "Ready" ]] || fail "claim phase is $PHASE after resync, expected Ready"

# Delete one Deployment, wait for next resync
kubectl delete deployment "$DEPLOY_B" --ignore-not-found

FOUND=""
for _ in $(seq 1 45); do
  REFS=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.referencedBy}' 2>/dev/null || echo "")
  if echo "$REFS" | grep -q "$DEPLOY_A" && ! echo "$REFS" | grep -q "$DEPLOY_B"; then
    FOUND="one"
    break
  fi
  sleep 1
done

[[ "$FOUND" == "one" ]] || fail "referencedBy should contain only $DEPLOY_A after deleting $DEPLOY_B, got: $REFS"

# Phase still Ready
PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[[ "$PHASE" == "Ready" ]] || fail "claim phase is $PHASE after delete, expected Ready"

echo "PASS: resync computes referencedBy from live Deployments"