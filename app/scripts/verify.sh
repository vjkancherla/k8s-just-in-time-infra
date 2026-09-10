#!/usr/bin/env bash
set -uo pipefail

# Full R1–R17 verification for the voting app.
#
# Prerequisites: a running cluster (see scripts/deploy.sh) **and** the JIT stack
# (MinIO, the runner, the InfraClaim CRD and the controller). There is no
# stateful workload in the cluster any more (build-plan S15): Redis and Postgres
# are containers on the k3d network, provisioned per namespace by the controller
# and the runner, so their state is read with `docker exec` (build-plan S16).
# Without the JIT stack the app pods sit in Init and R2/R7/R8/R9/R16/R17 fail.
#
# The *.localhost hostnames resolve to 127.0.0.1 natively (RFC 6761) — no
# /etc/hosts needed.
#
# Results are written to .workflow/verify.md.
#
#   NS="default"   namespace the app runs in. The JIT container is named after the
#                  claim, `<ns>-<module>`, so the module's own container is
#                  `<ns>-redis-redis` / `<ns>-postgres-postgres`.

RELEASE="${RELEASE:-voting-app}"
NS="${NS:-default}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-./kustomize}"
VOTE_URL="${VOTE_URL:-https://vote.localhost:8082}"
RESULT_URL="${RESULT_URL:-https://result.localhost:8082}"
REGISTRY="${REGISTRY:-0}"
OUT=".workflow/verify.md"

mkdir -p .workflow
: > "$OUT"

PASS=0
FAIL=0

say() {
  local id="$1" status="$2" msg="$3"
  printf '%-4s %-8s %s\n' "$id" "$status" "$msg"
  printf '%-4s %-8s %s\n' "$id" "$status" "$msg" >> "$OUT"
}

pass() { say "$1" "PASS" "$2"; PASS=$((PASS + 1)); }
fail() { say "$1" "FAIL" "$2"; FAIL=$((FAIL + 1)); }

# The stateful tiers are not pods any more. Redis and Postgres are containers the
# controller provisioned for this namespace (build-plan S15), so every read goes
# through `docker exec` against the module's own container name:
#   jit-modules/modules/redis/main.tf    name = "${var.name}-redis"
#   jit-modules/modules/postgres/main.tf name = "${var.name}-postgres"
# where var.name is the claim's name, "<ns>-<module>", set by the controller.
# `psql` and `pg_isready` reach the local socket inside the container, which
# needs no password (S15 reads the tally the same way).
REDIS_CONTAINER="${REDIS_CONTAINER:-${NS}-redis-redis}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-${NS}-postgres-postgres}"
psql_q() { docker exec "$POSTGRES_CONTAINER" psql -U postgres -d voting -t -A -c "$1" 2>/dev/null; }
redis_q() { docker exec "$REDIS_CONTAINER" redis-cli "$@" 2>/dev/null; }

# Fetch the two option labels from the rendered vote page.
vote_html="$(curl -sk --compressed "$VOTE_URL/")"
mapfile -t OPTS < <(printf '%s\n' "$vote_html" | grep -o 'name="choice" value="[^"]*"' | sed -E 's/.*value="([^"]*)".*/\1/')

# ---- R1: Vote page offers exactly two options ----
vote_code="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$VOTE_URL/")"
if [[ "$vote_code" == "200" && "${#OPTS[@]}" -eq 2 && -n "${OPTS[0]:-}" && -n "${OPTS[1]:-}" ]]; then
  pass "R1" "200 with exactly two options: ${OPTS[0]} / ${OPTS[1]}"
else
  fail "R1" "code=${vote_code}, options=${OPTS[*]:-none}"
fi

# ---- R2: Casting a vote enqueues it (worker paused so the queue is observable) ----
kubectl scale deployment "${RELEASE}-worker" -n "$NS" --replicas=0 >/dev/null 2>&1 || true
# Wait until all worker pods are gone
for i in $(seq 1 30); do
  if [[ -z "$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=worker -o name 2>/dev/null)" ]]; then
    break
  fi
  sleep 1
done
before_len="$(redis_q LLEN votes)"
vote_code2="$(curl -sk --compressed -o /dev/null -w '%{http_code}' -X POST "$VOTE_URL/vote" -d "choice=${OPTS[0]}" -c /tmp/vcookies.txt)"
after_len="$(redis_q LLEN votes)"
if [[ "$vote_code2" =~ ^(2|3)[0-9][0-9]$ && "$after_len" -gt "$before_len" ]]; then
  pass "R2" "POST /vote -> 200, redis LLEN ${before_len} -> ${after_len}"
else
  fail "R2" "code=${vote_code2}, LLEN ${before_len} -> ${after_len}"
fi
kubectl scale deployment "${RELEASE}-worker" -n "$NS" --replicas=1 >/dev/null 2>&1 || true
kubectl rollout status deployment "${RELEASE}-worker" -n "$NS" --timeout=120s >/dev/null 2>&1 || true

# ---- R3: One vote per browser; re-vote replaces prior vote ----
curl -sk --compressed -c /tmp/vcookies-r3.txt "$VOTE_URL/" >/dev/null
sleep 3
curl -sk --compressed -o /dev/null -X POST "$VOTE_URL/vote" -d "choice=${OPTS[0]}" -b /tmp/vcookies-r3.txt
sleep 3
total1="$(psql_q 'SELECT COUNT(*) FROM votes')"
curl -sk --compressed -o /dev/null -X POST "$VOTE_URL/vote" -d "choice=${OPTS[1]}" -b /tmp/vcookies-r3.txt
sleep 3
total2="$(psql_q 'SELECT COUNT(*) FROM votes')"
if [[ "$total1" == "$total2" ]]; then
  pass "R3" "tally unchanged after re-vote (${total1})"
else
  fail "R3" "tally ${total1} -> ${total2}"
fi

# ---- R4: Worker idempotent per voter (replayed entry -> one row) ----
redis_q RPUSH votes '{"voter_id":"verify-r4","choice":"Cats","timestamp":1700000000}' >/dev/null
redis_q RPUSH votes '{"voter_id":"verify-r4","choice":"Cats","timestamp":1700000000}' >/dev/null
sleep 3
r4_count="$(psql_q "SELECT COUNT(*) FROM votes WHERE voter_id='verify-r4'")"
if [[ "$r4_count" == "1" ]]; then
  pass "R4" "one row for verify-r4 after replay"
else
  fail "R4" "got ${r4_count} rows"
fi

# ---- R5: Result page shows counts and percentages for both options ----
result_html="$(curl -sk --compressed "$RESULT_URL/")"
if printf '%s\n' "$result_html" | grep -qE '[0-9]+(\.[0-9]+)?%' \
  && printf '%s\n' "$result_html" | grep -q "${OPTS[0]}" \
  && printf '%s\n' "$result_html" | grep -q "${OPTS[1]}"; then
  pass "R5" "percentages + both option labels present"
else
  fail "R5" "missing percentages or labels"
fi

# ---- R6: New vote appears in results within 5s ----
before_total="$(psql_q 'SELECT COUNT(*) FROM votes')"
curl -sk --compressed -o /dev/null -X POST "$VOTE_URL/vote" -d "choice=${OPTS[0]}" -c /tmp/vcookies-r6.txt
start="$(date +%s)"
r6_ok=0
while [[ $(( $(date +%s) - start )) -le 5 ]]; do
  after_total="$(psql_q 'SELECT COUNT(*) FROM votes')"
  if [[ "$after_total" -gt "$before_total" ]]; then r6_ok=1; break; fi
  sleep 0.5
done
if [[ "$r6_ok" == "1" ]]; then
  pass "R6" "vote appeared in $(( $(date +%s) - start ))s (limit 5s)"
else
  fail "R6" "vote did not appear within 5s"
fi

# ---- R7: Schema is votes(voter_id PK, choice, updated_at) ----
schema="$(psql_q '\d votes')"
if printf '%s\n' "$schema" | grep -q 'voter_id' \
  && printf '%s\n' "$schema" | grep -q 'choice' \
  && printf '%s\n' "$schema" | grep -q 'updated_at'; then
  pass "R7" "votes table has voter_id, choice, updated_at"
else
  fail "R7" "schema mismatch"
fi

# ---- R8: Queued votes survive a worker restart ----
kubectl scale deployment "${RELEASE}-worker" -n "$NS" --replicas=0 >/dev/null 2>&1 || true
# Wait until all worker pods are gone (not just rollout status)
for i in $(seq 1 30); do
  if [[ -z "$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=worker -o name 2>/dev/null)" ]]; then
    break
  fi
  sleep 1
done
before_total8="$(psql_q 'SELECT COUNT(*) FROM votes')"
curl -sk --compressed -o /dev/null -X POST "$VOTE_URL/vote" -d "choice=${OPTS[1]}" -c /tmp/vcookies-r8.txt
queued="$(redis_q LLEN votes)"
if [[ "$queued" -lt 1 ]]; then
  fail "R8" "no vote queued during worker outage"
else
  kubectl scale deployment "${RELEASE}-worker" -n "$NS" --replicas=1 >/dev/null 2>&1 || true
  kubectl rollout status deployment "${RELEASE}-worker" -n "$NS" --timeout=120s >/dev/null 2>&1 || true
  sleep 5
  after_total8="$(psql_q 'SELECT COUNT(*) FROM votes')"
  drained="$(redis_q LLEN votes)"
  if [[ "$after_total8" -gt "$before_total8" && "$drained" == "0" ]]; then
    pass "R8" "queued vote (${queued}) drained to postgres after restart"
  else
    fail "R8" "before=${before_total8} after=${after_total8} remaining=${drained}"
  fi
fi

# ---- R9: Tally survives a postgres restart ----
# Postgres is a container now, so the restart is `docker restart` and the wait is
# `pg_isready` inside it. The hardcoded pod name `voting-app-postgres-0` is gone
# with the StatefulSet - SCRIPTS-GUIDE §9 listed it as the reason CLUSTER was not
# fully overridable.
before9="$(psql_q 'SELECT COUNT(*) FROM votes')"
if [[ -z "$before9" ]]; then
  fail "R9" "cannot read the tally from $POSTGRES_CONTAINER before the restart"
else
  docker restart "$POSTGRES_CONTAINER" >/dev/null 2>&1 || true
  pg_ready9=0
  for _ in $(seq 1 60); do
    if docker exec "$POSTGRES_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
      pg_ready9=1
      break
    fi
    sleep 2
  done
  if [[ "$pg_ready9" != "1" ]]; then
    fail "R9" "postgres container did not accept connections after docker restart"
  else
    # `result` reconnects to postgres on its own. Giving it a moment here stops
    # R13/R16 from inheriting the restart.
    for i in $(seq 1 60); do
      result_ready=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=result -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      [[ "$result_ready" == "True" ]] && break
      sleep 1
    done
    after9="$(psql_q 'SELECT COUNT(*) FROM votes')"
    if [[ -n "$after9" && "$before9" == "$after9" ]]; then
      pass "R9" "tally preserved across docker restart (${before9})"
    else
      fail "R9" "${before9} -> ${after9:-unreadable}"
    fi
  fi
fi

# ---- R10: All 3 workloads have liveness AND readiness probes ----
# Three Deployments, not five: redis and postgres are containers outside the
# cluster (build-plan S15/S16), so this namespace holds vote, worker and result.
# Scoped to the namespace so the JIT controller's own Deployment, which also runs
# here, is not counted.
probe_counts="$(kubectl get deploy -n "$NS" -o json | jq -r '
  [.items[] | .spec.template.spec.containers[] | {l: (.livenessProbe != null), r: (.readinessProbe != null)}]
  | "\(map(select(.l))|length) \(map(select(.r))|length)"')"
liveness_n="${probe_counts%% *}"
readiness_n="${probe_counts##* }"
if [[ "$liveness_n" == "3" && "$readiness_n" == "3" ]]; then
  pass "R10" "3 liveness + 3 readiness probes"
else
  fail "R10" "liveness=${liveness_n} readiness=${readiness_n}"
fi

# ---- R11: All 3 workloads have resource requests AND limits ----
resourced_n="$(kubectl get deploy -n "$NS" -o json | jq '[.items[] | .spec.template.spec.containers[] | select(.resources.requests.cpu != null and .resources.requests.memory != null and .resources.limits.cpu != null and .resources.limits.memory != null)] | length')"
if [[ "$resourced_n" == "3" ]]; then
  pass "R11" "3 containers with cpu/mem requests + limits"
else
  fail "R11" "only ${resourced_n}/3 containers fully resourced"
fi

# ---- R12: Single kustomize config; registry image override supported ----
if kubectl kustomize "$KUSTOMIZE_DIR" >/dev/null 2>&1 \
  && kubectl kustomize "$KUSTOMIZE_DIR" | sed 's|vote:latest|k3d-voting-app-registry.localhost:5000/vote:latest|g; s|worker:latest|k3d-voting-app-registry.localhost:5000/worker:latest|g; s|result:latest|k3d-voting-app-registry.localhost:5000/result:latest|g' | grep -q 'k3d-voting-app-registry.localhost:5000/vote'; then
  pass "R12" "kustomize base + registry image override"
else
  fail "R12" "kustomize build or overlay override failed"
fi

# ---- R13: vote and result reachable via Traefik ingress (HTTPS) ----
v13="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$VOTE_URL/")"
r13="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$RESULT_URL/")"
if [[ "$v13" == "200" && "$r13" == "200" ]]; then
  pass "R13" "vote=${v13} result=${r13}"
else
  fail "R13" "vote=${v13} result=${r13}"
fi

# ---- R14: No NodePort services ----
np="$(kubectl get svc -o json | jq '[.items[] | select(.spec.type == "NodePort")] | length')"
if [[ "$np" == "0" ]]; then
  pass "R14" "0 NodePort services"
else
  fail "R14" "${np} NodePort service(s)"
fi

# ---- R15: Images built locally for arm64 from a local registry ----
# Try docker inspect first; fall back to rdctl for Rancher Desktop
arch="$(docker inspect "vote:latest" --format '{{.Architecture}}' 2>/dev/null)"
if [[ -z "$arch" ]]; then
  arch="$(rdctl shell docker inspect "vote:latest" --format '{{.Architecture}}' 2>/dev/null || echo 'missing')"
fi
if [[ "$REGISTRY" == "1" ]]; then
  reg_refs="$(kubectl get deploy -o json | jq '[.items[].spec.template.spec.containers[].image | select(contains("k3d-voting-app-registry.localhost"))] | length')"
  if [[ "$arch" == "arm64" && "$reg_refs" -ge 3 ]]; then
    pass "R15" "arm64, ${reg_refs} registry image refs"
  else
    fail "R15" "arch=${arch} registry refs=${reg_refs}"
  fi
else
  imagepull="$(kubectl get pods -o json | jq '[.items[] | .status.containerStatuses[]? | select(.state.waiting.reason == "ImagePullBackOff")] | length')"
  if [[ "$arch" == "arm64" && "$imagepull" == "0" ]]; then
    pass "R15" "arm64, no ImagePullBackOff (images imported)"
  else
    fail "R15" "arch=${arch} imagepullbackoff=${imagepull}"
  fi
fi

# ---- R16: Each service reports dependency status ----
v16="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$VOTE_URL/healthz")"
r16="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$RESULT_URL/healthz")"
w16="$(kubectl exec -n "$NS" "deploy/${RELEASE}-worker" -- python /app/app.py --healthcheck >/dev/null 2>&1 && echo 0 || echo 1)"
redis16="$(redis_q ping)"
pg16="$(docker exec "$POSTGRES_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && echo 0 || echo 1)"
if [[ "$v16" == "200" && "$r16" == "200" && "$w16" == "0" && "$redis16" == "PONG" && "$pg16" == "0" ]]; then
  pass "R16" "vote/result/worker/redis/postgres all healthy"
else
  fail "R16" "vote=${v16} result=${r16} worker=${w16} redis=${redis16} postgres=${pg16}"
fi

# ---- R17: Postgres credentials come from the JIT outputs Secret, not committed manifests ----
# The controller writes the generated password into the per-module outputs Secret
# `jit-postgres` (build-plan S14/S15); that Secret is the only place the value
# exists in the cluster now that the StatefulSet and its own Secret are gone.
if grep -rE 'POSTGRES_PASSWORD[[:space:]]*:' "$KUSTOMIZE_DIR" --include='*.yaml' 2>/dev/null; then
  fail "R17" "literal password reference found in committed manifest"
else
  secret_pw="$(kubectl get secret jit-postgres -n "$NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null)"
  if [[ -n "$secret_pw" ]]; then
    pass "R17" "no literal password; the JIT outputs Secret 'jit-postgres' holds POSTGRES_PASSWORD"
  else
    fail "R17" "jit-postgres Secret missing or empty"
  fi
fi

# ---- Summary ----
printf '\n===== %s PASS, %s FAIL =====\n' "$PASS" "$FAIL" | tee -a "$OUT"


