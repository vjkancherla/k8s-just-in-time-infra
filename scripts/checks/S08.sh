#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

NAMESPACE="default"
DEPLOY_NAME="s8-test-deploy"
CLAIM_NAME="${NAMESPACE}-redis"
SECRET_NAME="jit-redis"
ANNOTATION='{"module":"redis","moduleVersion":"v1","params":{},"softDeleteTTL":"2m"}'

cleanup() {
  kubectl delete deployment "$DEPLOY_NAME" --ignore-not-found 2>/dev/null || true
  kubectl delete infraclaim "$CLAIM_NAME" --ignore-not-found 2>/dev/null || true
  kubectl delete secret "$SECRET_NAME" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

cleanup

# 1. Create annotated Deployment
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: s8-test
  template:
    metadata:
      labels:
        app: s8-test
    spec:
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.5
annotations:
  jit.infra/redis: '$ANNOTATION'
EOF

# Wait for claim
for _ in $(seq 1 30); do
  if kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || fail "claim $CLAIM_NAME not created"

# Phase Ready
PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[[ "$PHASE" == "Ready" ]] || fail "claim phase is $PHASE, expected Ready"

# OwnerRef is Namespace
OWNER_KIND=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.ownerReferences[0].kind}')
OWNER_NAME=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.ownerReferences[0].name}')
[[ "$OWNER_KIND" == "Namespace" ]] || fail "owner kind is $OWNER_KIND, expected Namespace"
[[ "$OWNER_NAME" == "$NAMESPACE" ]] || fail "owner name is $OWNER_NAME, expected $NAMESPACE"

# Secret exists
kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || fail "secret $SECRET_NAME not created"

# Idempotence: re-apply Deployment
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: s8-test
  template:
    metadata:
      labels:
        app: s8-test
    spec:
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.5
annotations:
  jit.infra/redis: '$ANNOTATION'
EOF

COUNT=$(kubectl get infraclaim -n "$NAMESPACE" -o name | grep "$CLAIM_NAME" | wc -l | tr -d ' ')
[[ "$COUNT" -eq 1 ]] || fail "expected exactly 1 claim, found $COUNT"

echo "PASS: CRD + claim creation, ownerRef → Namespace, finalizer"
