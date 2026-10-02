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
# The cache-hit half of the goal: an identical re-POST is a no-op, not a re-apply.
# Without this, deleting the success cache entirely still passes every assertion.
created_after_identical="$(docker inspect -f '{{.Created}}' "$c")"
[ "$created_after_identical" = "$created1" ] \
  || fail "identical params replaced the container - the cached success was not returned (the cache must key on module+workspace+params and be a no-op for an identical hash)"

# --- 2. changed params: a REAL re-apply, not the cached no-op ----------------
post '{"module":"redis","version":"v1","workspace":"s24-check","params":{"name":"s24-check-redis","network":"k3d-voting-app","ip":"172.19.0.192","maxmemory":"128mb"}}' >/dev/null \
  || fail "changed-params re-POST failed"
created2="$(docker inspect -f '{{.Created}}' "$c")"
[ "$created2" != "$created1" ] \
  || fail "changed params returned the cached success - the container was not replaced (cache still keyed on workspace only)"

cmd="$(docker inspect -f '{{.Config.Cmd}}' "$c")"
echo "$cmd" | grep -q -- '--maxmemory 128mb' \
  || fail "replaced container does not run --maxmemory 128mb: $cmd"

# The changed-params re-apply replaces the cached run, so the replaced run's work dir must
# be gone: exactly one /tmp/jit-s24-check-* remains in the runner. Without this the work dir
# leaks on every update (ADR 0023 debt 1, ADR 0024) and no other assertion notices, because
# deleting the removal still passes every check above.
n_dirs() { docker exec jit-runner sh -c 'ls /tmp 2>/dev/null | grep -c "^jit-s24-check-" || true' | tr -d ' '; }
[ "$(n_dirs)" -eq 1 ] \
  || fail "the changed-params re-apply left $(n_dirs) work dir(s) under /tmp/jit-s24-check-*, not 1 - the replaced run's work dir leaked"

# --- 3. the conditional's negative side: a redis-only destroy runs no state rm
log_before="$(docker logs jit-runner 2>&1 | wc -l)"
curl -s -X DELETE "http://$RUNNER/v1/runs/s24-check" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" >/dev/null \
  || fail "destroy of s24-check failed"
docker ps -a --format '{{.Names}}' | grep -qx "$c" \
  && fail "container still exists after destroy"
[ "$(n_dirs)" -eq 0 ] \
  || fail "destroy left $(n_dirs) work dir(s) under /tmp/jit-s24-check-* - the work dir must go with the run"
new_logs="$(docker logs jit-runner 2>&1 | tail -n +$((log_before+1)))"
echo "$new_logs" | grep -qi 'state rm' \
  && fail "a run whose state holds no postgresql_* resources ran 'tofu state rm' - the design makes it conditional on the state"

# --- 4. the conditional's positive side: postgres in state, container pre-removed.
# destroy must still succeed (the deleted container would fail the refresh if the
# postgresql_* resources were still in state), and the volume goes with the container.
#
# The postgres module does not create postgresql_* resources until S27, so this
# checkpoint injects one into the workspace's state itself: without it the refresh
# succeeds whether or not the runner runs `state rm`, and the positive side asserts
# nothing. The injected resource is a real state entry of the type S27 will manage.
PGWS=s24-pg
resp="$(post "{\"module\":\"postgres\",\"version\":\"v1\",\"workspace\":\"$PGWS\",\"params\":{\"name\":\"$PGWS\",\"network\":\"k3d-voting-app\",\"ip\":\"172.19.0.191\",\"databases\":[\"voting\"],\"postgres_password\":\"s24-probe\"}}")"
[ "$(echo "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status"))')" = "success" ] \
  || fail "postgres workspace create failed: $resp"
docker exec jit-runner sh -lc "
set -e
d=\$(mktemp -d)
cp -r /opt/jit-modules/modules/postgres/. \"\$d/\"
cd \"\$d\"
export AWS_ACCESS_KEY_ID=jit-state AWS_SECRET_ACCESS_KEY=jit-state-secret-2026 AWS_DEFAULT_REGION=us-east-1
tofu init -input=false \
  -backend-config bucket=jit-state -backend-config key=ns/$PGWS/postgres/terraform.tfstate \
  -backend-config endpoint=http://172.19.0.11:9000 -backend-config access_key=jit-state \
  -backend-config secret_key=jit-state-secret-2026 -backend-config region=us-east-1 \
  -backend-config skip_credentials_validation=true -backend-config skip_metadata_api_check=true \
  -backend-config force_path_style=true >/dev/null 2>&1
tofu state pull > /tmp/s24-st.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/s24-st.json'))
d['serial'] = d.get('serial', 1) + 1
d.setdefault('resources', []).append({
    'mode': 'managed', 'type': 'postgresql_database', 'name': 'voting',
    'provider': 'provider[\"registry.opentofu.org/cyrilgdn/postgresql\"]',
    'instances': [{'schema_version': 0,
                   'attributes': {'id': 'voting', 'name': 'voting', 'owner': 'postgres'},
                   'sensitive_attributes': []}],
})
json.dump(d, open('/tmp/s24-st2.json', 'w'))
PY
tofu state push /tmp/s24-st2.json
tofu state list | grep -q '^postgresql_' || { echo 'inject failed'; exit 1; }
" || fail "could not inject a postgresql_* resource into $PGWS state"
docker rm -f -v "$PGWS-postgres" >/dev/null 2>&1 \
  || fail "pre-removal of the postgres container failed"
log_before="$(docker logs jit-runner 2>&1 | wc -l)"
del="$(curl -s -X DELETE "http://$RUNNER/v1/runs/$PGWS" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"module\":\"postgres\",\"params\":{\"name\":\"$PGWS\",\"network\":\"k3d-voting-app\",\"postgres_password\":\"s24-probe\"}}")"
echo "$del" | grep -qiE 'success|destroyed' \
  || fail "destroy after container pre-removal failed (state rm must drop postgresql_* from state first) - $del"
new_logs="$(docker logs jit-runner 2>&1 | tail -n +$((log_before+1)))"
echo "$new_logs" | grep -qi 'state rm' \
  || fail "the destroy of a workspace whose state holds postgresql_* did not run 'tofu state rm' - $new_logs"
docker ps -a --format '{{.Names}}' | grep -qx "$PGWS-postgres" \
  && fail "the postgres container survived the destroy"
docker volume ls --format '{{.Name}}' | grep -qx "$PGWS-postgres-data" \
  && fail "the postgres data volume outlived its container (a retained volume carries a password the next stack cannot use)"
echo "PASS S24: cache keyed on params; changed params re-apply; state rm conditional on postgresql_* in state; volume goes with its container"
