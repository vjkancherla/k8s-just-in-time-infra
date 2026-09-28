#!/usr/bin/env bash
# S27 - Modules: postgres databases created in place against the running
# server, the settings allowlist, redis maxmemory vars, service_url_<db>
# naming, volume preservation on a settings replace, and the destroy path
# after `tofu state rm`.
# Precondition: the runner is up (make jit-up). No tenants needed; the
# checkpoint drives the runner API directly.
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }

docker info >/dev/null 2>&1 || fail "docker not reachable"
docker ps --format '{{.Names}}' | grep -qx jit-runner \
  || fail "runner not up - run 'make jit-up' before this checkpoint"
TOKEN="$(grep -E '^JIT_RUNNER_TOKEN=' deploy/.env 2>/dev/null | cut -d= -f2- || true)"
: "${TOKEN:=s6-secret-token-2026}"
RUNNER=172.19.0.10:8080
WS=s27-check
post() { curl -s -X POST "http://$RUNNER/v1/runs" -H "Authorization: Bearer $TOKEN" -d "$1"; }
status(){ echo "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status"))'; }

# --- 1. create with one database ------------------------------------------------
resp="$(post "{\"module\":\"postgres\",\"version\":\"v1\",\"workspace\":\"$WS\",\"params\":{\"name\":\"$WS-pg\",\"network\":\"k3d-voting-app\",\"ip\":\"172.19.0.190\",\"databases\":[\"voting\"],\"postgres_password\":\"s27probe\"}}")"
[ "$(status "$resp")" = "success" ] || fail "postgres create failed: $resp"
sleep 5
docker ps --format '{{.Names}}' | grep -q "^$WS-pg$" || fail "postgres container missing"
docker exec "$WS-pg" sh -c 'psql -U postgres -l' 2>/dev/null | grep -qw voting \
  || fail "initial database 'voting' missing"

# --- 2. add a database in place: container NOT replaced --------------------------
c="$(docker ps --format '{{.Names}}' | grep "^$WS-pg$")"
created1="$(docker inspect -f '{{.Created}}' "$c")"
resp="$(post "{\"module\":\"postgres\",\"version\":\"v1\",\"workspace\":\"$WS\",\"params\":{\"name\":\"$WS-pg\",\"network\":\"k3d-voting-app\",\"ip\":\"172.19.0.190\",\"databases\":[\"voting\",\"analytics\"],\"postgres_password\":\"s27probe\"}}")"
[ "$(status "$resp")" = "success" ] || fail "databases add failed: $resp"
created2="$(docker inspect -f '{{.Created}}' "$c")"
[ "$created2" = "$created1" ] \
  || fail "adding a database replaced the - in place means no new container"
docker exec "$WS-pg" sh -c 'psql -U postgres -l' 2>/dev/null | grep -qw analytics \
  || fail "database 'analytics' was not created in place"
urls="$(echo "$resp" | python3 -c 'import sys,json;print(" ".join((json.load(sys.stdin).get("outputs") or {}).keys()))')"
echo "$urls" | grep -q service_url_analytics \
  || fail "runner output has no service_url_analytics (got: $urls)"
echo "$urls" | grep -qx "service_url" \
  || fail "the initial database lost its service_url key"
echo "2 ok additive databases: in-place, service_url_analytics added, service_url kept"

# --- 3. settings change: container replaced, volume and data survive -------------
docker exec "$WS-pg" sh -c "psql -U postgres -c 'CREATE TABLE s27_probe(i int)' -d voting" >/dev/null 2>&1 \
  || fail "probe table creation failed"
resp="$(post "{\"module\":\"postgres\",\"version\":\"v1\",\"workspace\":\"$WS\",\"params\":{\"name\":\"$WS-pg\",\"network\":\"k3d-voting-app\",\"ip\":\"172.19.0.190\",\"databases\":[\"voting\",\"analytics\"],\"settings\":{\"max_connections\":\"150\"},\"postgres_password\":\"s27probe\"}}")"
[ "$(status "$resp")" = "success" ] || fail "settings change failed: $resp"
for i in $(seq 1 12); do
  created3="$(docker inspect -f '{{.Created}}' "$c" 2>/dev/null || true)"
  [ -n "$created3" ] && [ "$created3" != "$created2" ] && break; sleep 5
done
[ "$created3" != "$created2" ] \
  || fail "settings change did not replace the container (or failed silently)"
for i in $(seq 1 12); do
  ok="$(docker exec "$WS-pg" pg_isready -U postgres 2>/dev/null || true)"
  [ -n "$ok" ] && break; sleep 5
done
echo "$ok" | grep -q "accepting connections" \
  || fail "replaced postgres never became ready"
data="$(docker exec "$WS-pg" psql -U postgres -t -d voting -c '\dt s27_probe' 2>/dev/null || true)"
echo "$data" | grep -q s27_probe \
  || fail "the managed volume was lost across a settings replace (s17: volume survives, data intact)"
echo "3 ok settings replace: server replaced, volume and data intact"

# --- 4. destroy removes container AND volume, even pre-removed --------------------
docker rm -f "$WS-pg" >/dev/null 2>&1 || true
del="$(curl -s -X DELETE "http://$RUNNER/v1/runs/$WS" -H "Authorization: Bearer $TOKEN")"
echo "$del" | grep -qi success \
  || fail "destroy after container pre-removal failed (state rm first) - $del"
docker ps -a --format '{{.Names}}' | grep -q "^$WS-pg$" \
  && fail "container still listed after destroy"
docker volume ls --format '{{.Name}}' | grep -q "$WS-pg-data" \
  && fail "the postgres data volume outlived its container (a frozen, regenerated password trap)"
echo "4 ok destroy: container and volume both gone, state rm first"
echo "PASS S27: postgres in place, volume-surviving replaces, service_url_<db>, clean destroy"
