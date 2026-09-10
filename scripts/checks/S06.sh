#!/usr/bin/env bash
#
# Checkpoint S6 - jit-runner as a local process, idempotent create, auth enforced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

RUNNER_URL="http://127.0.0.1:8100"
TOKEN="s6-secret-token-2026"
WORKSPACE="s6-test"
MODULE="redis"
CLUSTER_NET="k3d-voting-app"
TEST_IP="172.19.0.50"
BUCKET="jit-state"
STATE_KEY="ns/${WORKSPACE}/${MODULE}/terraform.tfstate"
REDIS_CONTAINER="${WORKSPACE}-redis"

if [[ -f "$SCRIPT_DIR/deploy/.env" ]]; then
  MINIO_ROOT_USER="$(grep -E '^MINIO_ROOT_USER=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2-)"
  MINIO_ROOT_PASSWORD="$(grep -E '^MINIO_ROOT_PASSWORD=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2-)"
fi
: "${MINIO_ROOT_USER:?set MINIO_ROOT_USER in deploy/.env}"
: "${MINIO_ROOT_PASSWORD:?set MINIO_ROOT_PASSWORD in deploy/.env}"

export AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
export AWS_DEFAULT_REGION="us-east-1"

DOCKER_HOST="${DOCKER_HOST:-}"
if ! docker -H unix:///var/run/docker.sock ps >/dev/null 2>&1; then
  DOCKER_HOST="unix:///Users/vkancherla/.rd/docker.sock"
fi
export DOCKER_HOST

fail() { echo "FAIL: $1"; exit 1; }

cleanup() {
  if [[ -n "${RUNNER_PID:-}" ]]; then
    kill "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  docker -H "$DOCKER_HOST" rm -f "$WORKSPACE-probe" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: build JSON payload via printf (shell vars expand)
json_payload() {
  printf '{"module":"%s","workspace":"%s","params":{"name":"%s","ip":"%s","network":"%s"}}' "$1" "$2" "$2" "$3" "$4"
}

# ---------------------------------------------------------------------------
# 0. Ensure runner is healthy
# ---------------------------------------------------------------------------

for _ in $(seq 1 30); do
  if curl -s -o /dev/null -w "%{http_code}" "$RUNNER_URL/health" 2>/dev/null | grep -q "200"; then
    break
  fi
  sleep 1
done
curl -s "$RUNNER_URL/health" >/dev/null || fail "runner not healthy at $RUNNER_URL"

# ---------------------------------------------------------------------------
# 1. POST /v1/runs -> 200, outputs contain redis URL, container exists
# ---------------------------------------------------------------------------

PAYLOAD=$(json_payload "$MODULE" "$WORKSPACE" "$TEST_IP" "$CLUSTER_NET")
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$RUNNER_URL/v1/runs" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
[[ "$HTTP_CODE" == "200" ]] || fail "POST returned $HTTP_CODE, expected 200 (body: $BODY)"
echo "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='success', f'not success: {d}'; print('  create: ok')" || fail "runner returned non-success status"

# Verify the redis container exists
for _ in $(seq 1 30); do
  if docker -H "$DOCKER_HOST" inspect "$REDIS_CONTAINER" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker -H "$DOCKER_HOST" inspect "$REDIS_CONTAINER" >/dev/null 2>&1 || \
  fail "redis container $REDIS_CONTAINER does not exist"

# Verify correct IP
CONTAINER_IP=$(docker -H "$DOCKER_HOST" inspect "$REDIS_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['${CLUSTER_NET}']['IPAddress'])" 2>/dev/null)
[[ "$CONTAINER_IP" == "$TEST_IP" ]] || fail "container IP is $CONTAINER_IP, expected $TEST_IP"

# ---------------------------------------------------------------------------
# 2. POST /v1/runs again -> 200, still one container (idempotent)
# ---------------------------------------------------------------------------

RESPONSE2=$(curl -s -w "\n%{http_code}" -X POST "$RUNNER_URL/v1/runs" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "$PAYLOAD")

HTTP_CODE2=$(echo "$RESPONSE2" | tail -1)
BODY2=$(echo "$RESPONSE2" | sed '$d')
[[ "$HTTP_CODE2" == "200" ]] || fail "idempotent POST returned $HTTP_CODE2, expected 200"
echo "$BODY2" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='success', f'not success: {d}'; print('  idempotent: ok')" || fail "runner returned non-success on idempotent call"

# Verify still only one container
CONTAINER_COUNT=$(docker -H "$DOCKER_HOST" ps -a --filter "name=${REDIS_CONTAINER}" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
[[ "$CONTAINER_COUNT" -eq 1 ]] || fail "expected 1 container, found $CONTAINER_COUNT"

# ---------------------------------------------------------------------------
# 3. DELETE /v1/runs/{workspace} -> container gone
# ---------------------------------------------------------------------------

RESPONSE3=$(curl -s -w "\n%{http_code}" -X DELETE "$RUNNER_URL/v1/runs/$WORKSPACE" \
  -H "Authorization: Bearer $TOKEN")

HTTP_CODE3=$(echo "$RESPONSE3" | tail -1)
BODY3=$(echo "$RESPONSE3" | sed '$d')
[[ "$HTTP_CODE3" == "200" ]] || fail "DELETE returned $HTTP_CODE3, expected 200"
echo "$BODY3" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='destroyed', f'not destroyed: {d}'; print('  destroy: ok')" || fail "runner returned non-destroyed status"

# Verify container is gone
for _ in $(seq 1 10); do
  if ! docker -H "$DOCKER_HOST" inspect "$REDIS_CONTAINER" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker -H "$DOCKER_HOST" inspect "$REDIS_CONTAINER" >/dev/null 2>&1 && \
  fail "redis container $REDIS_CONTAINER still exists after destroy" || true

# ---------------------------------------------------------------------------
# 4. Bad token -> 401
# ---------------------------------------------------------------------------

RESPONSE4=$(curl -s -w "\n%{http_code}" -X POST "$RUNNER_URL/v1/runs" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer wrong-token" \
  -d "$PAYLOAD")

HTTP_CODE4=$(echo "$RESPONSE4" | tail -1)
[[ "$HTTP_CODE4" == "401" ]] || fail "bad token returned $HTTP_CODE4, expected 401"
echo "  auth check: ok (401 on bad token)"

echo "PASS: jit-runner local process, idempotent create, auth enforced"
