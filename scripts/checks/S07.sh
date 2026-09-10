#!/usr/bin/env bash
#
# Checkpoint S7 - jit-runner containerised at 172.19.0.10, driven from inside the cluster.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

RUNNER_URL="http://172.19.0.10:8080"
TOKEN="s6-secret-token-2026"
WORKSPACE="s7-test"
MODULE="redis"
CLUSTER_NET="k3d-voting-app"
TEST_IP="172.19.0.55"
REDIS_CONTAINER="${WORKSPACE}-redis"
POD_NAME="s7-curl"

fail() { echo "FAIL: $1"; exit 1; }

cleanup() {
  kubectl delete pod "$POD_NAME" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

# 0. Clean up any leftover from a previous run
cleanup
docker rm -f "$REDIS_CONTAINER" >/dev/null 2>&1 || true

# 1. Run a curl pod to reach the runner from inside the cluster
kubectl run "$POD_NAME" --image=busybox --restart=Never -- sleep 60
kubectl wait --for=condition=Ready pod/"$POD_NAME" --timeout=30s || fail "pod not ready"

# 1a. Health check from inside the cluster
kubectl exec "$POD_NAME" -- wget -qO- --timeout=5 "$RUNNER_URL/health" >/dev/null || fail "runner not healthy at $RUNNER_URL from inside cluster"
echo "  health check: ok"

# 2. Create via runner from inside the cluster (single quotes for exact JSON)
RESP=$(kubectl exec "$POD_NAME" -- wget -qO- --timeout=120 \
  --post-data="{\"module\":\"${MODULE}\",\"workspace\":\"${WORKSPACE}\",\"params\":{\"name\":\"${WORKSPACE}\",\"ip\":\"${TEST_IP}\",\"network\":\"${CLUSTER_NET}\"}}" \
  --header="Authorization: Bearer $TOKEN" \
  --header="Content-Type: application/json" \
  "$RUNNER_URL/v1/runs")
echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='success', f'not success: {d}'; print('  create: ok')" || fail "runner returned non-success status on create"

# Verify the container exists and has the correct IP
for _ in $(seq 1 30); do
  if docker inspect "$REDIS_CONTAINER" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker inspect "$REDIS_CONTAINER" >/dev/null 2>&1 || fail "redis container $REDIS_CONTAINER does not exist"

CONTAINER_IP=$(docker inspect "$REDIS_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | python3 -c "import json,sys; print(json.load(sys.stdin)['${CLUSTER_NET}']['IPAddress'])" 2>/dev/null)
[[ "$CONTAINER_IP" == "$TEST_IP" ]] || fail "container IP is $CONTAINER_IP, expected $TEST_IP"
echo "  container created at $CONTAINER_IP: ok"

# 3. Idempotent create
RESP2=$(kubectl exec "$POD_NAME" -- wget -qO- --timeout=120 \
  --post-data="{\"module\":\"${MODULE}\",\"workspace\":\"${WORKSPACE}\",\"params\":{\"name\":\"${WORKSPACE}\",\"ip\":\"${TEST_IP}\",\"network\":\"${CLUSTER_NET}\"}}" \
  --header="Authorization: Bearer $TOKEN" \
  --header="Content-Type: application/json" \
  "$RUNNER_URL/v1/runs")
echo "$RESP2" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='success', f'not success: {d}'; print('  idempotent: ok')" || fail "runner returned non-success on idempotent create"

CONTAINER_COUNT=$(docker ps -a --filter "name=${REDIS_CONTAINER}" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
[[ "$CONTAINER_COUNT" -eq 1 ]] || fail "expected 1 container, found $CONTAINER_COUNT"

# 4. Destroy via runner (busybox's wget doesn't support DELETE; use Python on runner container)
docker exec -i jit-runner python3 -c "
import urllib.request, json
req = urllib.request.Request('http://127.0.0.1:8080/v1/runs/${WORKSPACE}', method='DELETE')
req.add_header('Authorization', 'Bearer ${TOKEN}')
resp = urllib.request.urlopen(req)
d = json.loads(resp.read())
assert d['status'] == 'destroyed', f'not destroyed: {d}'
print('  destroy: ok')
" || fail "runner returned non-destroyed status"

# Verify container is gone
for _ in $(seq 1 10); do
  if ! docker inspect "$REDIS_CONTAINER" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker inspect "$REDIS_CONTAINER" >/dev/null 2>&1 && fail "container still exists after destroy" || true

echo "PASS: jit-runner containerised at 172.19.0.10, driven from inside the cluster"