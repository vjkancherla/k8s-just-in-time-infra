#!/usr/bin/env bash
set -euo pipefail

# scripts/verify-jit.sh - the J1-J11 lifecycle acceptance suite (build-plan S17).
#
#   make jit-verify   ->   .workflow/verify-jit.md, exit non-zero if any J FAILs
#
# J1-J11 are the acceptance tests from docs/jit-infra-poc.md. Unlike
# app/scripts/verify.sh - which is a *report* and therefore uses `set -uo pipefail`
# without `-e`, so a failing check still exits 0 - this is a gate: it uses
# `set -euo pipefail` and exits non-zero on the first failure. Later J-checks
# depend on the state earlier ones establish, so carrying on after one breaks
# would report noise rather than information.
#
# It deploys the two demo namespaces itself (J1 *is* "deploy into voting-a", J8
# *is* "delete ns voting-b"), with softDeleteTTL forced to 2m so J6 does not wait
# ten minutes. The base annotations say 10m; the sed below is what the step means
# by "implementing J1-J11 with softDeleteTTL: 2m".
#
# Prerequisites: `make jit-up` (MinIO, runner, CRD, controller) and a k3d cluster.
#
# Read-guards: every `docker exec` read that a comparison depends on is checked
# for emptiness and the container is named in the failure. S16's review concern 1
# was exactly this - two empty reads compare equal, so an unguarded comparison can
# pass while the dependency is gone.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

A="voting-a"
B="voting-b"
CTRL_NS="default"
TTL="2m"
MODULES="redis postgres pgadmin"
OUT=".workflow/verify-jit.md"

mkdir -p .workflow
: > "$OUT"

PASS=0
FAIL=0

say() {
  local id="$1" status="$2" msg="$3"
  printf '%-3s %-4s %s\n' "$id" "$status" "$msg"
  printf '%-3s %-4s %s\n' "$id" "$status" "$msg" >> "$OUT"
}
pass() { say "$1" PASS "$2"; PASS=$((PASS + 1)); }
fail() {
  say "$1" FAIL "$2"
  FAIL=$((FAIL + 1))
  printf '\n===== %s PASS, %s FAIL =====\n' "$PASS" "$FAIL" | tee -a "$OUT"
  exit 1
}


# ── Helpers ──────────────────────────────────────────────────────────────────

render_ns() {  # the overlay, with the retention window shortened to 2m
  kubectl kustomize "app/kustomize/overlays/$1" \
    | sed "s/\"softDeleteTTL\":\"10m\"/\"softDeleteTTL\":\"$TTL\"/g"
}
apply_ns() { render_ns "$1" | kubectl apply -f - >/dev/null; }

phase_of() { kubectl get infraclaim "$1" -n "$2" -o jsonpath='{.status.phase}' 2>/dev/null || true; }
expires_of() { kubectl get infraclaim "$1" -n "$2" -o jsonpath='{.status.expiresAt}' 2>/dev/null || true; }
message_of() { kubectl get infraclaim "$1" -n "$2" -o jsonpath='{.status.message}' 2>/dev/null || true; }
refs_of() { kubectl get infraclaim "$1" -n "$2" -o jsonpath='{.status.referencedBy}' 2>/dev/null || true; }
claim_gone() { ! kubectl get infraclaim "$1" -n "$2" >/dev/null 2>&1; }

wait_phase() {  # <ns> <claim> <phase> <timeout>
  local ns="$1" name="$2" want="$3" timeout="$4" start=$SECONDS phase=""
  while (( SECONDS - start < timeout )); do
    phase="$(phase_of "$name" "$ns")"
    [[ "$phase" == "$want" ]] && return 0
    sleep 3
  done
  echo "    $ns/$name stayed '${phase:-<absent>}' for ${timeout}s, wanted '$want'" >&2
  return 1
}

wait_gone() {  # <ns> <claim> <timeout>
  local ns="$1" name="$2" timeout="$3" start=$SECONDS
  while (( SECONDS - start < timeout )); do
    claim_gone "$name" "$ns" && return 0
    sleep 3
  done
  echo "    $ns/$name still exists after ${timeout}s (phase '$(phase_of "$name" "$ns")')" >&2
  return 1
}

wait_deploy() {  # <ns> <deployment> <timeout>
  kubectl rollout status "deployment/$2" -n "$1" --timeout="$3" >/dev/null 2>&1
}

container_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null || true; }
container_id() { docker inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }
is_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]; }
gone() { ! docker container inspect "$1" >/dev/null 2>&1; }

psql_q() { docker exec "$1" psql -U postgres -d voting -t -A -c "$2" 2>/dev/null || true; }
redis_q() { docker exec "$1" redis-cli "${@:2}" 2>/dev/null || true; }

reset_ns() {  # <ns> - back to "never deployed", for a repeatable run
  local ns="$1" ic m
  for ic in $(kubectl get infraclaims -n "$ns" -o name 2>/dev/null || true); do
    kubectl patch "$ic" -n "$ns" --type=json \
      -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null 2>&1 || true


  done
  kubectl delete infraclaim -n "$ns" --all --ignore-not-found --wait=true >/dev/null 2>&1 || true
  for m in $MODULES; do docker rm -f "${ns}-${m}-${m}" >/dev/null 2>&1 || true; done
  # The module names its volume "${var.name}-postgres-data" with var.name "<ns>-postgres",
  # so the volume is "<ns>-postgres-postgres-data" - one "-postgres" more than the container.
  docker volume rm -f "${ns}-postgres-postgres-data" >/dev/null 2>&1 || true
  kubectl delete ns "$ns" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    kubectl get ns "$ns" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
      | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1 || true
  fi
}

# ── Preconditions ────────────────────────────────────────────────────────────

J=PREREQ
docker container inspect jit-runner >/dev/null 2>&1 \
  || fail "$J" "the jit-runner container is not running - run 'make jit-up'"
kubectl get crd infraclaims.jit.io >/dev/null 2>&1 \
  || fail "$J" "the InfraClaim CRD is not installed - run 'make jit-up'"
kubectl get deployment/jit-controller -n "$CTRL_NS" >/dev/null 2>&1 \
  || fail "$J" "the controller is not deployed - run 'make jit-up'"
docker network inspect k3d-voting-app >/dev/null 2>&1 \
  || fail "$J" "the k3d-voting-app network is missing"

# vote.localhost must belong to voting-a alone: R1-R17 and J2 drive that ingress,
# and a second namespace serving the same host routes unpredictably through
# Traefik.
other_host="$(kubectl get ingress -A -o json 2>/dev/null \
  | jq -r '.items[] | select((.spec.rules // [])[]?.host == "vote.localhost") | .metadata.namespace' \
  | grep -v "^${A}$" || true)"
[[ -z "$other_host" ]] \
  || fail "$J" "an Ingress outside $A claims vote.localhost (${other_host//$'\n'/, }) - one namespace per demo host"

reset_ns "$A"
reset_ns "$B"
kubectl create ns "$A" >/dev/null || fail "$J" "could not create namespace $A"
echo "    $A and $B reset; softDeleteTTL forced to $TTL"

# ═══ J1 - deploy into voting-a: three claims Ready, three containers, one block ═══

J=J1
apply_ns "$A"
for m in $MODULES; do
  wait_phase "$A" "$A-$m" Ready 240 \
    || fail "$J" "claim $A-$m did not reach Ready (phase '$(phase_of "$A-$m" "$A")', message '$(message_of "$A-$m" "$A")')"
  docker container inspect "$A-$m-$m" >/dev/null 2>&1 \
    || fail "$J" "claim $A-$m is Ready but container $A-$m-$m does not exist"
done
for d in vote worker result; do
  wait_deploy "$A" "voting-app-$d" 300s || fail "$J" "deployment voting-app-$d is not Ready in $A"
done

ips=()
for m in $MODULES; do
  ip="$(container_ip "$A-$m-$m")"
  [[ -n "$ip" ]] || fail "$J" "container $A-$m-$m reports no IP"
  declared="$(kubectl get infraclaim "$A-$m" -n "$A" -o jsonpath='{.status.allocatedIP}' 2>/dev/null || true)"
  [[ "$ip" == "$declared" ]] \
    || fail "$J" "$A-$m: container IP $ip does not match status.allocatedIP '${declared:-<none>}'"
  ips+=("$ip")
done
[[ "$(printf '%s\n' "${ips[@]}" | sort -u | wc -l | tr -d ' ')" == "3" ]] \
  || fail "$J" "the three containers do not have three distinct IPs: ${ips[*]}"
lo=999; hi=0
for ip in "${ips[@]}"; do
  last="${ip##*.}"
  [[ "$ip" == 172.19.0.* && "$last" -ge 100 && "$last" -le 199 ]] \
    || fail "$J" "$ip is outside the 172.19.0.100-199 IPAM range"
  # `if`, not `cond && assign`: a false condition as the last statement of the
  # loop body would make the loop return 1 and trip `set -e`.
  if (( last < lo )); then lo="$last"; fi
  if (( last > hi )); then hi="$last"; fi
done
(( hi - lo <= 9 )) \
  || fail "$J" "the three IPs ${ips[*]} do not come from one block of 10 (spread $((hi - lo + 1)))"
pass "$J" "deployed into $A: 3 claims Ready, 3 containers on ${ips[*]} (one block of 10)"

# ═══ J2 - Secrets, Services, EndpointSlices; then R1-R17 in voting-a ═══

J=J2
for m in $MODULES; do
  kubectl get secret "jit-$m" -n "$A" >/dev/null 2>&1 || fail "$J" "Secret jit-$m is missing in $A"
  kubectl get service "jit-$m" -n "$A" >/dev/null 2>&1 || fail "$J" "Service jit-$m is missing in $A"
  kubectl get endpointslice "jit-$m" -n "$A" >/dev/null 2>&1 || fail "$J" "EndpointSlice jit-$m is missing in $A"
done

R_MD="app/.workflow/verify.md"
rm -f "$R_MD"
( cd app && NS="$A" ./scripts/verify.sh ) >/dev/null 2>&1 || true
[[ -f "$R_MD" ]] || fail "$J" "the R-check suite wrote no report at $R_MD"
r_summary="$(grep -E '^===== [0-9]+ PASS, [0-9]+ FAIL =====$' "$R_MD" | tail -1 || true)"
if [[ "$r_summary" != "===== 17 PASS, 0 FAIL =====" ]]; then
  echo "    failing R-checks:" >&2
  grep -E '^R[0-9]+[[:space:]]+FAIL' "$R_MD" | head -20 >&2 || true
  fail "$J" "expected '===== 17 PASS, 0 FAIL =====' in $R_MD, got '${r_summary:-no summary line}'"
fi
pass "$J" "3 Secrets + Services + EndpointSlices present; R1-R17 = ${r_summary#===== }"

# ═══ J3 - pgAdmin reachable, Postgres registered, Service port correct ═══

J=J3
pg="${A}-pgadmin-pgadmin"
pg_ip="$(container_ip "$A-postgres-postgres")"
[[ -n "$pg_ip" ]] || fail "$J" "container $A-postgres-postgres reports no IP"

code=""
for _ in $(seq 1 30); do
  code="$(curl -s -L -o /dev/null -w '%{http_code}' http://localhost:5050/ 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && break
  sleep 2
done
[[ "$code" == "200" ]] \
  || fail "$J" "pgAdmin did not answer HTTP 200 on http://localhost:5050/ (got ${code:-000})"

# The registration file is bind-mounted from the shared directory the runner passes
# to tofu as TF_VAR_share_dir. Before S17 the daemon could not see the runner's own
# /tmp, so Docker created an empty *directory* here and pgAdmin started with no
# server registered.
reg="$(docker exec "$pg" cat /pgadmin4/servers.json 2>/dev/null || true)"
[[ -n "$reg" ]] || fail "$J" "cannot read /pgadmin4/servers.json inside $pg"
reg_host="$(printf '%s' "$reg" | jq -r '.Nameservers.servers[0].Host // empty' 2>/dev/null || true)"
reg_port="$(printf '%s' "$reg" | jq -r '.Nameservers.servers[0].Port // empty' 2>/dev/null || true)"
[[ "$reg_host" == "$pg_ip" ]] \
  || fail "$J" "pgAdmin registered Host '${reg_host:-<none>}', expected the postgres container IP $pg_ip"
[[ "$reg_port" == "5432" ]] \
  || fail "$J" "pgAdmin registered Port '${reg_port:-<none>}', expected 5432"

svc_port="$(kubectl get service jit-pgadmin -n "$A" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
[[ "$svc_port" == "80" ]] \
  || fail "$J" "Service jit-pgadmin advertises port '${svc_port:-<none>}', expected 80 - the container's own port"
pass "$J" "pgAdmin HTTP 200 on :5050, registered $reg_host:$reg_port, Service jit-pgadmin port $svc_port"

# ═══ J4 - delete a Deployment: infra keeps running, other workloads unaffected ═══

J=J4
ids_before="$(for m in $MODULES; do printf '%s=%s ' "$m" "$(container_id "$A-$m-$m")"; done)"
before_rows="$(psql_q "$A-postgres-postgres" 'SELECT COUNT(*) FROM votes')"
[[ -n "$before_rows" ]] \
  || fail "$J" "cannot read the tally from $A-postgres-postgres before deleting the Deployment"
id_count="$(for m in $MODULES; do container_id "$A-$m-$m"; done | grep -c . || true)"
[[ "$id_count" == "3" ]] \
  || fail "$J" "could not read all three container ids before the delete: [$ids_before]"

kubectl delete deployment voting-app-vote -n "$A" --wait=true >/dev/null
for m in postgres pgadmin; do
  wait_phase "$A" "$A-$m" Orphaned 150 \
    || fail "$J" "claim $A-$m did not go Orphaned after deleting the vote Deployment"
  [[ -n "$(expires_of "$A-$m" "$A")" ]] \
    || fail "$J" "claim $A-$m is Orphaned but carries no expiresAt, so it would never be swept"
done
[[ "$(phase_of "$A-redis" "$A")" == "Ready" ]] \
  || fail "$J" "claim $A-redis is '$(phase_of "$A-redis" "$A")' although voting-app-worker still annotates redis"
for m in $MODULES; do
  is_running "$A-$m-$m" \
    || fail "$J" "container $A-$m-$m is not running: deleting a Deployment must not stop the infra"
done

# "the worker still functions": the queue must still drain into Postgres.
#
# One attempt is not enough. app/worker/app.py BLPOPs destructively and drops its
# connection on error, so the vote in flight when the server went away is lost -
# the file documents that window, and J2's R9 restarted Postgres. Measured on this
# cluster: baseline landed, the first message after the restart did not, the next
# one did. So the assertion is that the worker recovers and lands a vote, not that
# the very first attempt survives.
marker="jit-j4"
landed=0
for _ in 1 2 3; do
  redis_q "$A-redis-redis" RPUSH votes \
    "{\"voter_id\":\"$marker\",\"choice\":\"Cats\",\"timestamp\":1700000000}" >/dev/null
  for _ in $(seq 1 10); do
    n="$(psql_q "$A-postgres-postgres" "SELECT COUNT(*) FROM votes WHERE voter_id='$marker'")"
    if [[ "$n" == "1" ]]; then landed=1; break 2; fi
    sleep 2
  done
done
[[ "$landed" == "1" ]] \
  || fail "$J" "the worker drained nothing into Postgres in 3 attempts after the vote Deployment was deleted"
queued="$(redis_q "$A-redis-redis" LLEN votes)"
[[ -z "$queued" || "$queued" == "0" ]] \
  || fail "$J" "the queue still holds '${queued}' entries; the worker is not draining it"
pass "$J" "vote deleted: postgres+pgadmin Orphaned with expiresAt, all 3 containers still running, worker still drained a vote"

# ═══ J5 - redeploy inside the window: same containers, data intact ═══

J=J5
apply_ns "$A"
for m in $MODULES; do
  wait_phase "$A" "$A-$m" Ready 180 \
    || fail "$J" "claim $A-$m did not return to Ready after redeploying inside the window (phase '$(phase_of "$A-$m" "$A")')"
done
for d in vote worker result; do
  wait_deploy "$A" "voting-app-$d" 300s || fail "$J" "deployment voting-app-$d is not Ready after the redeploy"
done
ids_after="$(for m in $MODULES; do printf '%s=%s ' "$m" "$(container_id "$A-$m-$m")"; done)"
[[ "$ids_before" == "$ids_after" ]] \
  || fail "$J" "containers were reprovisioned: [$ids_before] -> [$ids_after]"
after_rows="$(psql_q "$A-postgres-postgres" 'SELECT COUNT(*) FROM votes')"
[[ -n "$after_rows" ]] || fail "$J" "cannot read the tally from $A-postgres-postgres after the redeploy"
[[ "$after_rows" -eq $((before_rows + 1)) ]] \
  || fail "$J" "tally went ${before_rows} -> ${after_rows}; expected exactly one new row (J4's marker) and nothing else"
r4_rows="$(psql_q "$A-postgres-postgres" "SELECT COUNT(*) FROM votes WHERE voter_id='verify-r4'")"
[[ "$r4_rows" == "1" ]] \
  || fail "$J" "the row R4 wrote is gone ('${r4_rows:-<unreadable>}') - the data did not survive"
pass "$J" "redeployed inside the window: same 3 container ids, tally ${before_rows} -> ${after_rows} (+1 marker), R4's row intact"

# ═══ J6 - delete the Deployment and wait past the TTL: infra is destroyed ═══

J=J6
kubectl delete deployment voting-app-vote -n "$A" --wait=true >/dev/null
start=$SECONDS
for m in postgres pgadmin; do
  wait_gone "$A" "$A-$m" 300 \
    || fail "$J" "claim $A-$m was not swept after its 2m TTL expired"
  gone "$A-$m-$m" || fail "$J" "container $A-$m-$m survived the sweep"
  if kubectl get secret "jit-$m" -n "$A" >/dev/null 2>&1; then
    fail "$J" "Secret jit-$m survived the sweep"
  fi
  if kubectl get service "jit-$m" -n "$A" >/dev/null 2>&1; then
    fail "$J" "Service jit-$m survived the sweep"
  fi
  if kubectl get endpointslice "jit-$m" -n "$A" >/dev/null 2>&1; then
    fail "$J" "EndpointSlice jit-$m survived the sweep"
  fi
done
is_running "$A-redis-redis" \
  || fail "$J" "redis was destroyed although voting-app-worker still references it"
[[ "$(phase_of "$A-redis" "$A")" == "Ready" ]] \
  || fail "$J" "claim $A-redis is '$(phase_of "$A-redis" "$A")', expected Ready while the worker still references it"
# The data volume belongs to the module, so the destroy takes it with the
# container: a re-created Postgres must initdb fresh rather than come back holding
# a database whose password the controller has already forgotten. The module names
# it "<var.name>-postgres-data", i.e. one "-postgres" more than the container.
if docker volume inspect "${A}-postgres-postgres-data" >/dev/null 2>&1; then
  vol="present"
else
  vol="removed"
fi
pass "$J" "after the $TTL window postgres+pgadmin were swept in $((SECONDS - start))s (container, Secret, Service, EndpointSlice) while redis stayed up; postgres data volume $vol"

# ═══ J7 - both Deployment annotate redis; deleting only vote leaves it Ready ═══

J=J7
apply_ns "$A"
for m in postgres pgadmin; do
  wait_phase "$A" "$A-$m" Ready 240 \
    || fail "$J" "claim $A-$m did not come back Ready for J7 (phase '$(phase_of "$A-$m" "$A")')"
done
kubectl delete deployment voting-app-vote -n "$A" --wait=true >/dev/null

ok=0
for _ in $(seq 1 20); do
  if [[ "$(refs_of "$A-redis" "$A")" == '["voting-app-worker"]' ]]; then ok=1; break; fi
  sleep 3
done
[[ "$ok" == "1" ]] \
  || fail "$J" "claim $A-redis referencedBy is '$(refs_of "$A-redis" "$A")', expected [\"voting-app-worker\"] once vote was gone"
[[ "$(phase_of "$A-redis" "$A")" == "Ready" ]] \
  || fail "$J" "claim $A-redis is '$(phase_of "$A-redis" "$A")' - the last reference (worker) should keep it Ready"
wait_phase "$A" "$A-postgres" Orphaned 150 \
  || fail "$J" "claim $A-postgres stayed '$(phase_of "$A-postgres" "$A")'; with its only reference (vote) gone it must Orphan"
pass "$J" "vote gone: redis kept Ready + referencedBy [voting-app-worker] (last-reference rule) while postgres Orphaned"

apply_ns "$A"
for m in $MODULES; do
  wait_phase "$A" "$A-$m" Ready 240 \
    || fail "$J" "claim $A-$m did not return to Ready after restoring vote (phase '$(phase_of "$A-$m" "$A")')"
done
for d in vote worker result; do
  wait_deploy "$A" "voting-app-$d" 300s || fail "$J" "deployment voting-app-$d is not Ready after restoring vote"
done

# ═══ J8 - delete ns voting-b: immediate teardown, voting-a untouched ═══

J=J8
kubectl create ns "$B" >/dev/null 2>&1 || true
kubectl get ns "$B" >/dev/null 2>&1 || fail "$J" "could not create namespace $B"
apply_ns "$B"
for m in $MODULES; do
  wait_phase "$B" "$B-$m" Ready 300 \
    || fail "$J" "claim $B-$m did not reach Ready in the second namespace (phase '$(phase_of "$B-$m" "$B")', message '$(message_of "$B-$m" "$B")')"
  docker container inspect "$B-$m-$m" >/dev/null 2>&1 \
    || fail "$J" "claim $B-$m is Ready but container $B-$m-$m does not exist"
done
# Second pgAdmin in a second namespace only exists because voting-b parameterises
# http_port through the claim's params (the module's host port is fixed).
b_pg_port="$(kubectl get service jit-pgadmin -n "$B" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
[[ "$b_pg_port" == "80" ]] || fail "$J" "Service jit-pgadmin in $B advertises '${b_pg_port:-<none>}', expected 80"

# A Ready claim carries no expiresAt, so nothing but the namespace delete can
# destroy this infra - which is what makes "the TTL was ignored" a real assertion.
for m in $MODULES; do
  [[ -z "$(expires_of "$B-$m" "$B")" ]] \
    || fail "$J" "claim $B-$m already carries expiresAt before the namespace delete"
done

start=$SECONDS
kubectl delete ns "$B" --timeout=300s >/dev/null 2>&1 || true
elapsed=$((SECONDS - start))
if kubectl get ns "$B" >/dev/null 2>&1; then
  fail "$J" "namespace $B survived the delete (still Terminating) - the finalizer path did not complete"
fi
for m in $MODULES; do
  gone "$B-$m-$m" \
    || fail "$J" "container $B-$m-$m survived the namespace delete of $B"
done
# voting-a untouched
for m in $MODULES; do
  is_running "$A-$m-$m" \
    || fail "$J" "deleting $B stopped voting-a's container $A-$m-$m"
  [[ "$(phase_of "$A-$m" "$A")" == "Ready" ]] \
    || fail "$J" "voting-a's claim $A-$m is '$(phase_of "$A-$m" "$A")' after $B was deleted"
done
wait_deploy "$A" voting-app-vote 120s \
  || fail "$J" "voting-a's vote Deployment stopped being Ready when $B was deleted"
pass "$J" "deleted ns $B: its 3 containers and claims were gone in ${elapsed}s with no TTL armed (hard path), voting-a's 3 claims still Ready"

# ═══ J9 - controller restart: the orphan is still detected ═══
#
# The Deployment has no delete handler - orphaning is done by the resync - so a
# Deployment deleted while the controller is down is invisible until the next
# resync. This is the check most designs skip (the design note says so twice).

J=J9
kubectl scale deployment/jit-controller -n "$CTRL_NS" --replicas=0 >/dev/null
ctrl_pods=1
for _ in $(seq 1 30); do
  ctrl_pods="$(kubectl get pods -n "$CTRL_NS" -l app=jit-controller --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$ctrl_pods" == "0" ]]; then break; fi
  sleep 2
done
[[ "$ctrl_pods" == "0" ]] || fail "$J" "the controller pod did not scale to 0 (still $ctrl_pods)"

kubectl delete deployment voting-app-vote -n "$A" --wait=true >/dev/null
kubectl scale deployment/jit-controller -n "$CTRL_NS" --replicas=1 >/dev/null
kubectl rollout status deployment/jit-controller -n "$CTRL_NS" --timeout=180s >/dev/null \
  || fail "$J" "the controller did not come back after the restart"

for m in postgres pgadmin; do
  wait_phase "$A" "$A-$m" Orphaned 180 \
    || fail "$J" "after the restart the resync left $A-$m '$(phase_of "$A-$m" "$A")' - the orphan was missed"
done
[[ "$(phase_of "$A-redis" "$A")" == "Ready" ]] \
  || fail "$J" "claim $A-redis is '$(phase_of "$A-redis" "$A")' after the restart, although the worker still references it"

# restore the demo state (the last two checks do not touch voting-a)
apply_ns "$A"
for m in $MODULES; do
  wait_phase "$A" "$A-$m" Ready 240 \
    || fail "$J" "claim $A-$m did not return to Ready after J9 (phase '$(phase_of "$A-$m" "$A")')"
done
for d in vote worker result; do
  wait_deploy "$A" "voting-app-$d" 300s || fail "$J" "deployment voting-app-$d is not Ready after J9"
done
pass "$J" "controller was down when vote was deleted; the restarted resync still marked postgres+pgadmin Orphaned and redis stayed Ready"

# ═══ J10 - runner down: the claim fails loudly, pods do not start ═══

J=J10
# The runner is stopped for this check. Put it back on *every* path, including the
# first failing assertion - the same mistake R8's worker restore made in S16: a gate
# that pauses a service owns restoring it, or the next run fails somewhere unrelated.
trap 'docker start jit-runner >/dev/null 2>&1 || true' EXIT
docker stop jit-runner >/dev/null
# Deploy with the provisioning service unreachable. redis and postgres hit the
# runner directly and must fail with a readable message. pgadmin depends on the
# postgres Secret: it must not become Failed (Failed is terminal until the
# Deployment changes) - and note that a claim waiting on a dependency has *no* phase
# at all, not "Pending" as the design's state machine calls it.
kubectl create ns "$B" >/dev/null 2>&1 || true
kubectl get ns "$B" >/dev/null 2>&1 || fail "$J" "could not create namespace $B"
apply_ns "$B"
for m in redis postgres; do
  wait_phase "$B" "$B-$m" Failed 180 \
    || fail "$J" "claim $B-$m is '$(phase_of "$B-$m" "$B")' with the runner stopped, expected Failed"
  msg="$(message_of "$B-$m" "$B")"
  [[ -n "$msg" ]] || fail "$J" "claim $B-$m is Failed but carries no message for the tenant"
done
kubectl get infraclaim "$B-pgadmin" -n "$B" >/dev/null 2>&1 \
  || fail "$J" "claim $B-pgadmin was never created - each jit.infra annotation must produce one"
pg_phase="$(phase_of "$B-pgadmin" "$B")"
[[ -z "$pg_phase" || "$pg_phase" == "Pending" ]] \
  || fail "$J" "claim $B-pgadmin is '$pg_phase'; with no jit-postgres Secret to depend on it must stay pending, never Failed"
for m in $MODULES; do
  if is_running "$B-$m-$m"; then
    fail "$J" "container $B-$m-$m started although the runner was down"
  fi
done
for d in vote worker result; do
  ready="$(kubectl get deployment "voting-app-$d" -n "$B" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -z "$ready" || "$ready" == "0" ]] \
    || fail "$J" "deployment voting-app-$d reports $ready ready replicas although nothing was provisioned"
done
docker start jit-runner >/dev/null
back=0
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8100/health >/dev/null 2>&1; then back=1; break; fi
  sleep 2
done
[[ "$back" == "1" ]] || fail "$J" "the runner did not come back up after 'docker start jit-runner'"
pass "$J" "runner stopped: redis+postgres Failed with a message, pgadmin '${pg_phase:-<no phase>}' (pending), no container started, no pod Ready - runner restored"

# The Failed claims are terminal and their namespace is about to be destroyed;
# the runner is back, so the finalizer path can complete.
reset_ns "$B"

# ═══ J11 - one state object per namespace-module, under distinct prefixes ═══

J=J11
env_get() { grep -E "^$1=" deploy/.env 2>/dev/null | head -n1 | cut -d= -f2-; }
mu="$(env_get MINIO_ROOT_USER)"
mp="$(env_get MINIO_ROOT_PASSWORD)"
[[ -n "$mu" && -n "$mp" ]] || fail "$J" "deploy/.env has no MINIO_ROOT_USER / MINIO_ROOT_PASSWORD"

# List the bucket with a SigV4 GET (the aws CLI is unusable here - see
# deploy/minio.sh, which creates the bucket the same way). Prints one key per line.
keys="$(AWS_ACCESS_KEY_ID="$mu" AWS_SECRET_ACCESS_KEY="$mp" \
  BUCKET="jit-state" PREFIX="ns/" \
  MINIO_ENDPOINT="http://127.0.0.1:9000" MINIO_HOST="127.0.0.1:9000" \
  python3 - <<'PY' || true
import datetime, hashlib, hmac, os, sys, urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

endpoint = os.environ["MINIO_ENDPOINT"]
bucket = os.environ["BUCKET"]
access = os.environ["AWS_ACCESS_KEY_ID"]
secret = os.environ["AWS_SECRET_ACCESS_KEY"]
host = os.environ["MINIO_HOST"]
prefix = os.environ.get("PREFIX", "")

now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y%m%dT%H%M%SZ")
date = now.strftime("%Y%m%d")

def sign(k, msg):
    return hmac.new(k, msg.encode("utf-8"), hashlib.sha256).digest()

query = "list-type=2"
if prefix:
    # The canonical query string uses S3's encoding, where "/" is %2F. Signing the
    # raw "ns/" (safe="/") and then sending it that way made MinIO answer HTTP 403
    # SignatureDoesNotMatch - J11's first real execution, because no earlier run had
    # ever reached it with a non-empty prefix. deploy/minio.sh needs no such care:
    # its PUT has no query string at all.
    query += "&prefix=" + urllib.parse.quote(prefix, safe="")

ch = "host:%s\nx-amz-date:%s\n" % (host, ts)
sh = "host;x-amz-date"
ph = hashlib.sha256(b"").hexdigest()
cr = "GET\n/%s\n%s\n%s\n%s\n%s" % (bucket, query, ch, sh, ph)
scope = "%s/%s/%s/aws4_request" % (date, "us-east-1", "s3")
sts = "AWS4-HMAC-SHA256\n%s\n%s\n%s" % (ts, scope, hashlib.sha256(cr.encode("utf-8")).hexdigest())
k = ("AWS4" + secret).encode("utf-8")
kd = sign(k, date); kr = sign(kd, "us-east-1"); ks = sign(kr, "s3")
ksig = sign(ks, "aws4_request")
sig = hmac.new(ksig, sts.encode("utf-8"), hashlib.sha256).hexdigest()
auth = "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (access, scope, sh, sig)

req = urllib.request.Request("%s/%s?%s" % (endpoint, bucket, query), method="GET")
req.add_header("Host", host)
req.add_header("x-amz-date", ts)
req.add_header("x-amz-content-sha256", ph)
req.add_header("Authorization", auth)
try:
    body = urllib.request.urlopen(req, timeout=10).read()
except urllib.error.HTTPError as e:
    print("MinIO list failed: HTTP %s %s" % (e.code, e.read().decode("utf-8", "replace")[:200]),
          file=sys.stderr)
    sys.exit(1)

ns = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
for c in ET.fromstring(body).findall("s3:Contents", ns):
    print(c.find("s3:Key", ns).text)
PY
)"

[[ -n "$keys" ]] || fail "$J" "could not list the jit-state bucket (is MinIO up? see 'make jit-up')"
for m in $MODULES; do
  grep -qx "ns/$A/$m/terraform.tfstate" <<< "$keys" \
    || fail "$J" "no state object ns/$A/$m/terraform.tfstate (keys: $(tr '\n' ' ' <<< "$keys"))"
done
grep -q "^ns/$B/" <<< "$keys" \
  || fail "$J" "no state object under the ns/$B/ prefix - each namespace must own its own keys"
odd="$(grep -vE '^ns/[^/]+/[^/]+/terraform\.tfstate$' <<< "$keys" || true)"
[[ -z "$odd" ]] \
  || fail "$J" "unexpected keys in the bucket: $(tr '\n' ' ' <<< "$odd")"

# J11 is the only check whose assertions are all negative (fail-only), so without an
# explicit pass() it reported nothing: it passed, the suite exited 0 on ten checks,
# and this gate - which requires a 'J11 PASS' line - could never be satisfied.
pass "$J" "jit-state holds ns/$A/{redis,postgres,pgadmin}/terraform.tfstate and an ns/$B/ prefix, every key ns/<ns>/<module>/terraform.tfstate"

# ── Summary ──────────────────────────────────────────────────────────────────

printf '\n===== %s PASS, %s FAIL =====\n' "$PASS" "$FAIL" | tee -a "$OUT"
[[ "$FAIL" -eq 0 ]] || exit 1





