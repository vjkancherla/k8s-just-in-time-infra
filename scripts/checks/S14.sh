#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

NAMESPACE="s14-test"
CLAIM_NAME="${NAMESPACE}-redis"
DEPLOY_NAME="s14-deploy"
ANNOTATION='{"module":"redis","moduleVersion":"v1","params":{},"softDeleteTTL":"60s"}'

cleanup() {
  kubectl delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete deployment "s14-deploy-b" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete job "s14-redis-test" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  # Remove container first (can't be blocked by namespace deletion)
  docker rm -f "${NAMESPACE}-redis-redis" 2>/dev/null || true
  # Remove finalizers from all claims so namespace deletion doesn't block
  for ic in $(kubectl get infraclaims -n "$NAMESPACE" -o name 2>/dev/null || true); do
    kubectl patch "$ic" -n "$NAMESPACE" --type=json \
      -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null || true
  done
  kubectl delete infraclaims -n "$NAMESPACE" --all --ignore-not-found 2>/dev/null || true
  # Delete namespace with timeout, force-finalize if stuck
  kubectl delete ns "$NAMESPACE" --ignore-not-found --timeout=30s 2>/dev/null || true
  if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    kubectl get ns "$NAMESPACE" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
      | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - 2>/dev/null || true
  fi
}
trap cleanup EXIT

# -- Preconditions --
docker inspect jit-runner >/dev/null 2>&1 || fail "jit-runner container not running"
CTRL_URL=$(kubectl get deployment jit-controller -n default \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RUNNER_URL")].value}' 2>/dev/null || echo "")
[[ -n "$CTRL_URL" ]] || fail "controller RUNNER_URL not set"

# -- Setup --
kubectl delete ns "$NAMESPACE" --ignore-not-found 2>/dev/null || true
# Wait for namespace to be fully gone before recreating
for _ in $(seq 1 60); do
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || break
  sleep 2
done
# Force-finalize if still stuck
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  for ic in $(kubectl get infraclaims -n "$NAMESPACE" -o name 2>/dev/null || true); do
    kubectl patch "$ic" -n "$NAMESPACE" --type=json \
      -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null || true
  done
  kubectl delete infraclaims -n "$NAMESPACE" --all --ignore-not-found 2>/dev/null || true
  kubectl get ns "$NAMESPACE" -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
    | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - 2>/dev/null || true
  # Wait again after force-finalize
  for _ in $(seq 1 30); do
    kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || break
    sleep 2
  done
fi
docker rm -f "${NAMESPACE}-redis-redis" 2>/dev/null || true
# Clean MinIO state and existing containers for this workspace
curl -s -X DELETE "http://127.0.0.1:8100/v1/runs/${NAMESPACE}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer s6-secret-token-2026" \
  -d "{\"module\":\"redis\",\"params\":{\"name\":\"${NAMESPACE}-redis\",\"network\":\"k3d-voting-app\"}}" >/dev/null 2>&1 || true
# Also remove any leftover container directly
docker rm -f "${NAMESPACE}-redis-redis" 2>/dev/null || true
# Create namespace — controller watches all namespaces, no restart needed
kubectl create ns "$NAMESPACE" 2>/dev/null || true

# ===========================================================================
# Phase 1: Annotate -> real container + Secret + Service + EndpointSlice
# ===========================================================================

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
        image: redis:7-alpine
EOF

for _ in $(seq 1 120); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  # Check if Ready AND Secret has data (handles stale Ready claims)
  if [[ "$PHASE" == "Ready" ]]; then
    SECRET_KEYS=$(kubectl get secret "jit-redis" -n "$NAMESPACE" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{})))" 2>/dev/null || echo "0")
    if [[ "$SECRET_KEYS" -gt 0 ]]; then
      break
    fi
  fi
  [[ "$PHASE" == "Failed" ]] && break
  sleep 2
done
[[ "$PHASE" == "Ready" ]] || fail "claim did not reach Ready, phase=$PHASE"

kubectl get secret "jit-redis" -n "$NAMESPACE" >/dev/null 2>&1 || fail "Secret jit-redis not found"
SECRET_KEYS=$(kubectl get secret "jit-redis" -n "$NAMESPACE" -o json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{})))")
[[ "$SECRET_KEYS" -gt 0 ]] || fail "Secret jit-redis has no data"

kubectl get service "jit-redis" -n "$NAMESPACE" >/dev/null 2>&1 || fail "Service jit-redis not found"

ALLOCATED_IP=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.allocatedIP}' 2>/dev/null || echo "")
[[ -n "$ALLOCATED_IP" ]] || fail "claim has no allocatedIP"

EP_ADDRS=$(kubectl get endpointslice -n "$NAMESPACE" \
  -l "kubernetes.io/service-name=jit-redis" \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || echo "")
[[ "$EP_ADDRS" == "$ALLOCATED_IP" ]] \
  || fail "EndpointSlice address=$EP_ADDRS != allocatedIP=$ALLOCATED_IP"

docker ps --format '{{.Names}}' | grep -q "${NAMESPACE}-redis-redis" \
  || fail "container ${NAMESPACE}-redis-redis not running"
CONTAINER_IP=$(docker inspect "${NAMESPACE}-redis-redis" \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
[[ "$CONTAINER_IP" == "$ALLOCATED_IP" ]] \
  || fail "container IP=$CONTAINER_IP != allocatedIP=$ALLOCATED_IP"

echo "PASS: real container at $ALLOCATED_IP, Secret + Service + EndpointSlice created"

# ===========================================================================
# Phase 2: Pod resolves Service and reaches Redis
# ===========================================================================

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: s14-redis-test
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: redis-test
        image: redis:7-alpine
        command: ["sh", "-c"]
        args:
        - |
          echo "Testing Redis via the Service name jit-redis:6379 ..."
          redis-cli -h jit-redis -p 6379 PING
        envFrom:
        - secretRef:
            name: jit-redis
            optional: true
EOF

for _ in $(seq 1 30); do
  SUCCEEDED=$(kubectl get job "s14-redis-test" -n "$NAMESPACE" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
  [[ "$SUCCEEDED" == "1" ]] && break
  sleep 2
done
[[ "$SUCCEEDED" == "1" ]] || fail "redis test job did not succeed"

JOB_POD=$(kubectl get pods -n "$NAMESPACE" -l "job-name=s14-redis-test" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
JOB_LOG=$(kubectl logs "$JOB_POD" -n "$NAMESPACE" 2>/dev/null || echo "")
echo "$JOB_LOG" | grep -qi "PONG" || fail "Redis PING did not return PONG. Log: $JOB_LOG"

echo "PASS: pod resolved Service and reached Redis (PONG received)"

# ===========================================================================
# Phase 3: Runner stopped -> claim Failed, pod stays unstarted
# ===========================================================================

echo "Stopping runner to simulate failure..."
docker stop jit-runner >/dev/null 2>&1

kubectl delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found
kubectl delete job "s14-redis-test" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

for _ in $(seq 1 65); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Orphaned" || "$PHASE" == "" ]] && break
  sleep 1
done

kubectl patch infraclaim "$CLAIM_NAME" -n "$NAMESPACE" --type=json \
  -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null || true
kubectl delete infraclaim "$CLAIM_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 3

# The workload below consumes the JIT Secret, so with the claim Failed (and therefore
# no Secret) the pod must stay unstarted for a reason that depends on the claim.
kubectl delete secret "jit-redis" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: s14-deploy-b
  namespace: $NAMESPACE
  annotations:
    jit.infra/redis: '$ANNOTATION'
spec:
  replicas: 1
  selector:
    matchLabels:
      app: s14-deploy-b
  template:
    metadata:
      labels:
        app: s14-deploy-b
    spec:
      containers:
      - name: workload
        image: redis:7-alpine
        envFrom:
        - secretRef:
            name: jit-redis
EOF

for _ in $(seq 1 120); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Failed" ]] && break
  sleep 2
done
[[ "$PHASE" == "Failed" ]] || fail "claim should be Failed with runner stopped, phase=$PHASE"

MSG=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.message}' 2>/dev/null || echo "")
[[ -n "$MSG" ]] || fail "Failed claim should have a message"
echo "  Failure message: $MSG"

# The pod must be held back by the missing JIT Secret, not by an unpullable image.
for _ in $(seq 1 30); do
  WAIT_REASON=$(kubectl get pods -n "$NAMESPACE" -l "app=s14-deploy-b" \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
  [[ -n "$WAIT_REASON" ]] && break
  sleep 2
done
POD_PHASE=$(kubectl get pods -n "$NAMESPACE" -l "app=s14-deploy-b" \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
[[ "$POD_PHASE" != "Running" ]] || fail "pod should not be Running when claim is Failed"
[[ "$WAIT_REASON" == "CreateContainerConfigError" ]] \
  || fail "pod should be blocked on the missing JIT Secret, waiting reason=$WAIT_REASON"
echo "  Pod held back by the claim: waiting reason=$WAIT_REASON"

echo "PASS: runner down -> claim Failed with message, pod unstarted"

docker start jit-runner >/dev/null 2>&1
sleep 5
kubectl delete deployment "s14-deploy-b" -n "$NAMESPACE" --ignore-not-found
kubectl patch infraclaim "$CLAIM_NAME" -n "$NAMESPACE" --type=json \
  -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' 2>/dev/null || true
kubectl delete infraclaim "$CLAIM_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 5
# Clean up runner cache and container for fresh Phase 4 provisioning
curl -s -X DELETE "http://127.0.0.1:8100/v1/runs/${NAMESPACE}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer s6-secret-token-2026" \
  -d "{\"module\":\"redis\",\"params\":{\"name\":\"${NAMESPACE}-redis\",\"network\":\"k3d-voting-app\"}}" >/dev/null 2>&1 || true
docker rm -f "${NAMESPACE}-redis-redis" 2>/dev/null || true
# Delete old Secret/Service/EndpointSlice so stale detection triggers
kubectl delete secret "jit-redis" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete service "jit-redis" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete endpointslice -l "kubernetes.io/service-name=jit-redis" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 3

# ===========================================================================
# Phase 4: Soft-delete lifecycle with real containers (S10 reprise)
# ===========================================================================

# Step 1: Create -> Ready
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
        image: redis:7-alpine
EOF

for _ in $(seq 1 120); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$PHASE" == "Ready" ]]; then
    SK=$(kubectl get secret "jit-redis" -n "$NAMESPACE" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{})))" 2>/dev/null || echo "0")
    [[ "$SK" -gt 0 ]] && break
  fi
  sleep 2
done
[[ "$PHASE" == "Ready" ]] || fail "claim did not reach Ready, phase=$PHASE"

SECRET_UID=$(kubectl get secret "jit-redis" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
[[ -n "$SECRET_UID" ]] || fail "Secret jit-redis not found"
echo "  Step 1: Ready, Secret uid=$SECRET_UID"

# Step 2: Delete -> Orphaned, Secret still present
kubectl delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found

for _ in $(seq 1 65); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Orphaned" ]] && break
  sleep 1
done
[[ "$PHASE" == "Orphaned" ]] || fail "should be Orphaned, phase=$PHASE"

EXPIRES=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.expiresAt}' 2>/dev/null || echo "")
[[ -n "$EXPIRES" && "$EXPIRES" != "null" ]] || fail "expiresAt not set"
kubectl get secret "jit-redis" -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "Secret gone during Orphaned"
echo "  Step 2: Orphaned (expires=$EXPIRES), Secret alive"

# Step 3: Re-apply within window -> Ready, expiry cleared, same Secret
# Delete+create to ensure the controller sees a fresh create event
kubectl delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
sleep 2
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
        image: redis:7-alpine
EOF

for _ in $(seq 1 65); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Ready" ]] && break
  sleep 1
done
[[ "$PHASE" == "Ready" ]] || fail "resurrection failed, phase=$PHASE"

EXPIRES_AFTER=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.expiresAt}' 2>/dev/null || echo "")
[[ -z "$EXPIRES_AFTER" || "$EXPIRES_AFTER" == "null" || "$EXPIRES_AFTER" == '""' ]] \
  || fail "expiresAt should be cleared, got: $EXPIRES_AFTER"

SECRET_UID2=$(kubectl get secret "jit-redis" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
[[ "$SECRET_UID2" == "$SECRET_UID" ]] || fail "Secret recreated"

# Wait for expiresAt to be cleared (controller needs time to process)
for _ in $(seq 1 30); do
  EXPIRES_AFTER=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.expiresAt}' 2>/dev/null || echo "")
  [[ -z "$EXPIRES_AFTER" || "$EXPIRES_AFTER" == "null" || "$EXPIRES_AFTER" == '""' ]] && break
  sleep 2
done
[[ -z "$EXPIRES_AFTER" || "$EXPIRES_AFTER" == "null" || "$EXPIRES_AFTER" == '""' ]] \
  || fail "expiresAt should be cleared, got: $EXPIRES_AFTER"
echo "  Step 3: Resurrected, same Secret"

# Step 4: Delete again, wait past TTL -> gone
kubectl delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found

for _ in $(seq 1 65); do
  PHASE=$(kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Orphaned" ]] && break
  sleep 1
done
[[ "$PHASE" == "Orphaned" ]] || fail "should be Orphaned again, phase=$PHASE"

# Make the sweep's destroy a COLD one: a restarted runner has no in-memory run
# cache, so it must load the module's state from the remote backend. That is the
# case that used to report success while destroying nothing.
docker restart jit-runner >/dev/null 2>&1
for _ in $(seq 1 30); do
  curl -s -m 3 http://127.0.0.1:8100/health >/dev/null 2>&1 && break
  sleep 2
done

# TTL=60s + 30s resync + 70s buffer = 160s
for _ in $(seq 1 160); do
  if ! kubectl get infraclaim "$CLAIM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    CLAIM_GONE=true
    break
  fi
  sleep 1
done
[[ "${CLAIM_GONE:-false}" == "true" ]] || fail "claim not swept after TTL"

if kubectl get secret "jit-redis" -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "Secret jit-redis should be gone after TTL expiry"
fi

# The actual teardown: the container has to be gone as well. Before the modules
# declared a remote backend, this destroy reported success and left it running.
if docker ps -a --format '{{.Names}}' | grep -qx "${NAMESPACE}-redis-redis"; then
  fail "container ${NAMESPACE}-redis-redis survived the TTL sweep (destroy claimed success)"
fi
echo "  Step 4: TTL swept — claim, Secret and container gone"

echo "PASS: S14 real provisioning verified"
