#!/usr/bin/env bash
# S24 - Runner: success cache keyed on module+workspace+params hash, and
# `tofu state rm` of postgresql_* before every destroy.
# Precondition: the runner container is up (make jit-up) and docker is reachable.
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }

docker info >/dev/null 2>&1 || fail "docker not reachable"
docker ps --format '{{.Names}}' | grep -qx jit-runner \
  || fail "runner not up - run 'make jit-up' before this checkpoint"

TOKEN="$(grep -E '^JIT_RUNNER_TOKEN=' deploy/.env 2>/dev/null | cut -d= -f2- || true)"
: "${TOKEN:=s6-secret-token-2026}"
RUNNER=127.0.0.1:8100
WS=s24-check
post() { curl -s -X POST "http://$RUNNER/v1/runs" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$1"; }

# --- 1. identical params twice: cached success, one container ----------------
post '{"module":"redis","version":"v1","workspace":"s24-check","params":{"name":"s24-check-redis","network":"k3d-voting-app","ip":"172.19.0.192","maxmemory":"256mb"}}' >/dev/null \
  || fail "first redis create did not succeed"
c="$(docker ps --format '{{.Names}}' | grep "$WS" | head -1)"
[ -n "$c" ] || fail "no container for workspace $WS after first create"
created1="$(docker inspect -f '{{.Created}}' "$c")"
resp2="$(post '{"module":"redis","version":"v1","workspace":"s24-check","params":{"name":"s24-check-redis","network":"k3d-voting-app","ip":"172.19.0.192","maxmemory":"256mb"}}')"
[ "$(echo "$resp2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')" = "success" ] \
  || fail "identical re-POST did not succeed"
n_cont="$(docker ps --format '{{.Names}}' | grep -c "$WS")"
[ "$n_cont" -eq 1 ] || fail "expected exactly one cached container, found $n_cont"

# --- 2. changed params: a REAL re-apply, not the cached no-op ----------------
post '{"module":"redis","version":"v1","workspace":"s24-check","params":{"name":"s24-check-redis","network":"k3d-voting-app","ip":"172.19.0.192","maxmemory":"128mb"}}' >/dev/null \
  || fail "changed-params re-POST failed"
created2="$(docker inspect -f '{{.Created}}' "$c")"
[ "$created2" != "$created1" ] \
  || fail "changed params returned the cached success - the container was not replaced (cache still keyed on workspace only)"

cmd="$(docker inspect -f '{{.Config.Cmd}}' "$c")"
echo "$cmd" | grep -q -- '--maxmemory 128mb' \
  || fail "replaced container does not run --maxmemory 128mb: $cmd"

# --- 3. the conditional's negative side: a redis-only destroy runs no state rm
log_before="$(docker logs jit-runner 2>&1 | wc -l)"
curl -s -X DELETE "http://$RUNNER/v1/runs/s24-check" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" >/dev/null \
  || fail "destroy of s24-check failed"
docker ps -a --format '{{.Names}}' | grep -qx "$c" \
  && fail "container still exists after destroy"
new_logs="$(docker logs jit-runner 2>&1 | tail -n +$((log_before+1)))"
echo "$new_logs" | grep -qi 'state rm' \
  && fail "a run whose state holds no postgresql_* resources ran 'tofu state rm' - the design makes it conditional on the state"

# --- 4. the conditional's positive side: postgres in state, container pre-removed.
# destroy must still succeed (the deleted container would fail the refresh if the
# postgresql_* resources were still in state), and the volume goes with the container.
PGWS=s24-pg
resp="$(post "{\"module\":\"postgres\",\"version\":\"v1\",\"workspace\":\"$PGWS\",\"params\":{\"name\":\"$PGWS\",\"network\":\"k3d-voting-app\",\"ip\":\"172.19.0.191\",\"databases\":[\"voting\"],\"postgres_password\":\"s24-probe\"}}")"
[ "$(echo "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status"))')" = "success" ] \
  || fail "postgres workspace create failed: $resp"
docker rm -f "$PGWS-postgres" >/dev/null 2>&1 \
  || fail "pre-removal of the postgres container failed"
del="$(curl -s -X DELETE "http://$RUNNER/v1/runs/$PGWS" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"module\":\"postgres\",\"params\":{\"name\":\"$PGWS\",\"network\":\"k3d-voting-app\",\"postgres_password\":\"s24-probe\"}}")"
echo "$del" | grep -qi success \
  || fail "destroy after container pre-removal failed (state rm must drop postgresql_* from state first) - $del"
docker ps -a --format '{{.Names}}' | grep -qx "$PGWS-postgres" \
  && fail "the postgres container survived the destroy"
docker volume ls --format '{{.Name}}' | grep -qx "$PGWS-postgres-data" \
  && fail "the postgres data volume outlived its container (a retained volume carries a password the next stack cannot use)"
echo "PASS S24: cache keyed on params; changed params re-apply; state rm conditional on postgresql_* in state; volume goes with its container"
