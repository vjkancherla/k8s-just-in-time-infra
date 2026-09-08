#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

NAMESPACE="default"
CLAIM_NAME="${NAMESPACE}-redis"
DEPLOY_NAME="s10-deploy"
ANNOTATION='{"module":"redis","moduleVersion":"v1","params":{},"softDeleteTTL":"2m"}'

cleanup() {
  kubectl delete deployment "$DEPLOY_NAME" --ignore-not-found 2>/dev/null || true
  # If claim is orphaned with a long TTL, force-clean it
  kubectl patch infraclaim "$CLAIM_NAME" -n "$NAMESPACE" --type=json \
    -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null || true
  kubectl delete infraclaim "$CLAIM_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

# Clean slate
kubectl delete deployment "$DEPLOY_NAME" --ignore-not-found 2>/dev/null || true

# If claim exists and is orphaned (leftover from a failed run), force-clean
EXISTING_PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$EXISTING_PHASE" == "Orphaned" ]]; then
  kubectl patch infraclaim "$CLAIM_NAME" -n "$NAMESPACE" --type=json \
    -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null || true
  kubectl delete infraclaim "$CLAIM_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  sleep 5
fi

# --- Step 1: Create Deployment, get to Ready ---

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
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

# Wait for claim to reach Ready
for _ in $(seq 1 60); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Ready" ]] && break
  sleep 2
done
[[ "$PHASE" == "Ready" ]] || fail "claim did not reach Ready, phase=$PHASE"

SECRET_BEFORE=$(kubectl get secret "jit-redis" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
[[ -n "$SECRET_BEFORE" ]] || fail "Secret jit-redis not found after claim is Ready"

# --- Phase 1: Delete last Deployment → Orphaned, Secret still present ---

kubectl delete deployment "$DEPLOY_NAME" --ignore-not-found

# Wait for claim to become Orphaned (up to ~65s: 2 resync cycles)
for _ in $(seq 1 65); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Orphaned" ]] && break
  sleep 1
done
[[ "$PHASE" == "Orphaned" ]] || fail "claim should be Orphaned after deleting last deploy, phase=$PHASE"

EXPIRES=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.expiresAt}' 2>/dev/null || echo "")
[[ -n "$EXPIRES" && "$EXPIRES" != "null" ]] || fail "expiresAt should be set when Orphaned, got: '$EXPIRES'"

kubectl get secret "jit-redis" -n "$NAMESPACE" >/dev/null 2>&1 || fail "Secret jit-redis should still exist when Orphaned"

echo "PASS: delete last Deployment → Orphaned with expiresAt, Secret still present"

# --- Phase 2: Re-apply within window → Ready, expiry cleared, same Secret ---

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
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

# Wait for claim to return to Ready (up to ~65s)
for _ in $(seq 1 65); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Ready" ]] && break
  sleep 1
done
[[ "$PHASE" == "Ready" ]] || fail "claim should be Ready after re-deploy, phase=$PHASE"

EXPIRES_AFTER=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.expiresAt}' 2>/dev/null || echo "")
[[ -z "$EXPIRES_AFTER" || "$EXPIRES_AFTER" == "null" ]] || fail "expiresAt should be cleared after resurrection, got: '$EXPIRES_AFTER'"

SECRET_AFTER=$(kubectl get secret "jit-redis" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
[[ "$SECRET_AFTER" == "$SECRET_BEFORE" ]] || fail "Secret should be the same (not recreated), before=$SECRET_BEFORE after=$SECRET_AFTER"

echo "PASS: re-apply within window → Ready, expiry cleared, same Secret"

# --- Phase 3: Delete again, wait past TTL (2m) → Secret gone, claim gone ---

kubectl delete deployment "$DEPLOY_NAME" --ignore-not-found

# Wait for Orphaned first
for _ in $(seq 1 65); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Orphaned" ]] && break
  sleep 1
done
[[ "$PHASE" == "Orphaned" ]] || fail "claim should be Orphaned after second delete, phase=$PHASE"

# Now wait for TTL to expire and sweep to clean up (2m TTL + 30s resync + buffer = ~180s)
for _ in $(seq 1 200); do
  if ! kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    CLAIM_GONE=true
    break
  fi
  sleep 1
done

[[ "${CLAIM_GONE:-false}" == "true" ]] || fail "claim should be gone after TTL expiry"

# Secret should also be gone
if kubectl get secret "jit-redis" -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "Secret jit-redis should be gone after TTL expiry"
fi

echo "PASS: delete again, wait past TTL → Secret gone, claim gone"
echo "PASS: S10 soft delete lifecycle verified"