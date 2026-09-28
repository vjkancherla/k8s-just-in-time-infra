#!/usr/bin/env bash
# S26 - Controller core against a stub runner: declarer resolution, the
# mutability contract, the update flow, backfill and stale-Updating recovery.
# No real containers are created - the stub runner records calls and can be
# told to fail a workspace (its name containing "s26fail").
# Precondition: the cluster and CRD are up (make jit-up). The script scales
# the in-cluster controller to 0 for the duration and ALWAYS scales it back.
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }

# Bodied kubectl: a dead API server cannot hang the checkpoint or its cleanup trap.
kk() { kubectl --request-timeout=5s "$@"; }

cleanup() { rc=$?; set +e
  rm -f "$STUB_LOG" "$STOPFILE" 2>/dev/null
  kill "${CTRL_PID:-0}" 2>/dev/null
  kill "${STUB_PID:-0}" 2>/dev/null
  kk scale deploy/jit-controller -n default --replicas=1 >/dev/null 2>&1
  kk delete ns "$NS" --wait=false --ignore-not-found >/dev/null 2>&1
  [ -n "${CTRL_PID:-}" ] && wait "$CTRL_PID" 2>/dev/null
  exit "$rc"; }
trap cleanup EXIT

NS=jit-stub
STUB_LOG="$(mktemp /tmp/s26-stub-XXXX.log)"
STOPFILE="$(mktemp)"

# --- preconditions -------------------------------------------------------------
kk get crd infraclaims.jit.io >/dev/null 2>&1 \
  || fail "CRD missing - run 'make jit-up' before this checkpoint"
[ -f jit-controller/stub_runner.py ] \
  || fail "jit-controller/stub_runner.py missing - S26 must ship the stub runner"

# silence the in-cluster controller so its handlers cannot fight the local one
kk scale deploy/jit-controller -n default --replicas=0 >/dev/null \
  || fail "could not scale in-cluster controller to 0"
kk delete ns "$NS" --ignore-not-found >/dev/null 2>&1 || true
kk create ns "$NS" >/dev/null || fail "scratch namespace creation failed"

# --- start the stub runner and a local controller ------------------------------
STUB_LOG="$STUB_LOG" python3 jit-controller/stub_runner.py &
STUB_PID=$!
sleep 1
kill -0 "$STUB_PID" 2>/dev/null || fail "stub runner did not start"
RUNNER_URL=http://127.0.0.1:8999 python3 jit-controller/main.py >/tmp/s26-controller.log 2>&1 &
CTRL_PID=$!

annot() { kk annotate deploy "voting-app-$1" -n "$NS" --overwrite "$2"; }
waitcond(){ claim="$1" cond="$2" val="$3"; for i in $(seq 1 8); do
  got="$(kk get infraclaim "$claim" -n "$NS" -o "jsonpath={range .status.conditions[*]}{.type}={.status}{'\n'}{end}" 2>/dev/null | grep -x "$cond=$val" || true)"
  [ -n "$got" ] && return 0; sleep 10; done; return 1; }
waitfield(){ claim="$1" p="$2"; for i in $(seq 1 8); do
  got="$(kk get infraclaim "$claim" -o "jsonpath=$p" 2>/dev/null)"; [ -n "$got" ] && { echo "$got"; return 0; }; sleep 10; done; return 1; }

stub_get() { grep -E "^POST module=$1 workspace=$2" "$STUB_LOG" || true; }
make() {
  kk apply -f - "$@" >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $1
  namespace: $NS
  labels: {app: probe}
  annotations:
    jit.infra/$2: '$3'
spec:
  replicas: 1
  selector: {matchLabels: {app: probe, id: "$1"}}
  template:
    metadata: {labels: {app: probe, id: "$1"}}
    spec:
      containers: [{name: pause, image: public.ecr.aws/aws-cli/aws-cli:latest, command: ["sh","-c","sleep 600"]}]
EOF
}

PGDECL='{"module":"redis","moduleVersion":"v1","params":{"maxmemory":"200mb"}}'
# --- 1. agree: declarer + consumer -> spec.params projected, declaredBy set ----
make d1 "redis" "$PGDECL" || fail "scratch deployment d1 failed"
make c1 "redis" '{"module":"redis"}'
base="$(waitfield "$NS-redis" '{.spec.params.maxmemory}')"
[ "$base" = "200mb" ] || fail "declarer params were not projected onto spec.params (got '$base')"
declared="$(waitfield "$NS-redis" '{.status.declaredBy}')"
echo "$declared" | grep -q d1 || fail "declaredBy does not name the declarer: $declared"
echo "1 ok declarer resolution; declaredBy=$declared"

# --- 2. disagree -> ParamsConflict naming both; desired stays at applied -------
sleep 5
make dnn "redis" '{"module":"redis","params":{"maxmemory":"999mb"}}'
waitcond "$NS-redis" "ParamsConflict" "True" \
  || fail "disagreeing declarers did not set ParamsConflict"
condmsg="$(kk get infraclaim "$NS-redis" -o jsonpath='{range .status.conditions[*]}{.type}:{.message}{end}')"
echo "$condmsg" | grep -q dnn || fail "ParamsConflict does not name the disagreeing declarer"
pg="$(kk get infraclaim "$NS-redis" -o jsonpath='{.spec.params.maxmemory}')"
[ "$pg" = "200mb" ] || fail "a disagreeing declarer moved spec.params"
n0="$(stub_get redis "$NS-redis" | wc -l | tr -d ' ')"
sleep 5
n1="$(stub_get redis "$NS-redis" | wc -l | tr -d ' ')"
[ "$n1" = "$n0" ] || fail "a conflict triggered a runner call"
echo "2 ok ParamsConflict among declarers only; no runner call"

# --- 3. back to agree clears it ------------------------------------------------
make dnn "redis" "$PGDECL"
waitcond "$NS-redis" "ParamsConflict" "False" || fail "ParamsConflict not cleared once declarers agree"
echo "3 ok agreement clears ParamsConflict"

# --- 4. refused edits: bad maxmemory value, unknown key -------------------------
make d1 "redis" '{"module":"redis","params":{"maxmemory":"banana"}}'
waitcond "$NS-redis" "UpdateRefused" "True" || fail "invalid maxmemory not refused"
c1="$(stub_get redis "$NS-redis")"; n0="$(echo "$c1" | wc -l | tr -d ' ')"
sleep 5; n1="$(stub_get redis "$NS-redis" | wc -l | tr -d ' ')"
[ "$n1" = "$n0" ] || fail "a refused value reached the runner"
echo "$c1" | grep -q banana && fail "a refused value was POSTed"
make d1 "redis" '{"module":"redis","params":{"wikijunk":"1"}}'
waitcond "$NS-redis" "UpdateRefused" "True" || fail "unknown key not refused"
echo "4 ok refused keys: named condition, no POST"

# --- 5. allowed update: a value DIFFERENT from appliedParams - Equal: never POSTed -
make d1 "redis" '{"module":"redis","params":{"maxmemory":"222mb"}}'
c2="$(stub_get redis "$NS-redis")"; n0="$(echo "$c2" | wc -l | tr -d ' ')"
for i in $(seq 1 9); do
  n1="$(stub_get redis "$NS-redis" | wc -l | tr -d ' ')"; [ "$n1" -g "$n0" ] && break; sleep 10
done
[ "$n1" -gt "$n0" ] || fail "allowed update never reached the stub runner"
ap="$(waitfield "$NS-redis" '{.status.appliedParams.maxmemory}')"
[ "$ap" = "222mb" ] || fail "appliedParams not written on success (got '$ap')"
hash="$(kk get infraclaim "$NS-redis" -o jsonpath='{.status.attemptedParamsHash}')"
[ -n "$hash" ] || fail "attemptedParamsHash not written before the POST"
waitcond "$NS-redis" "Updating" "False" || fail "Updating not cleared after the apply"
echo "5 ok successful update: POSTed, appliedParams+hash written, Updating cleared"

# --- 6. failure keeps Ready, one attempt, retried only on change ---------------
curl -s -X POST http://127.0.0.1:8999/mode/fail >/dev/null || fail "stub cannot accept fail mode"
sleep 3
make d1 "redis" '{"module":"redis","params":{"maxmemory":"150mb"}}'
waitcond "$NS-redis" "UpdateFailed" "True" || fail "runner failure did not set UpdateFailed"
ph="$(kk get infraclaim "$NS-redis" -o jsonpath='{.status.phase}')"
[ "$ph" = "Ready" ] || fail "failed update left phase $ph - the design keeps Ready"
ap="$(kk get infraclaim "$NS-redis" -o jsonpath='{.status.appliedParams.maxmemory}')"
[ "$ap" = "222mb" ] || fail "runner failure moved appliedParams: $ap"
n0="$(stub_get redis "$NS-redis" | wc -l | tr -d ' ')"
for i in 1 2 3; do sleep 20; n2="$(stub_get redis "$NS-redis" | wc -l | tr -d ' ')"; done
[ "$n2" = "$n0" ] || fail "a failed update was retried without the params changing"
curl -s -X POST http://127.0.0.1:8999/mode/ok >/dev/null || fail "stub cannot accept fail mode"
sleep 3
make d1 "redis" '{"module":"redis","params":{"maxmemory":"111mb"}}'
for i in $(seq 1 9); do
  ap="$(kk get infraclaim "$NS-redis" -o jsonpath='{.status.appliedParams.maxmemory}')"
  [ "$ap" = "111mb" ] && break; sleep 10
done
[ "$ap" = "111mb" ] || fail "desired change did not retry and converge"
waitcond "$NS-redis" "UpdateFailed" "False" || fail "UpdateFailed not cleared on success"
echo "6 ok failure: Ready kept, one attempt, retry on change, deactivated"

# --- 7. no declarer on an existing claim -> NoDeclarer, applied params kept -----
kk delete deploy d1 dnn -n "$NS" --ignore-not-found >/dev/null
waitcond "$NS-redis" "NoDeclarer" "True" || fail "loss of all declarers did not set NoDeclarer"
[ "$(kk get infraclaim "$NS-redis" -o jsonpath='{.status.phase}')" = "Ready" ] \
  || fail "claim stopped Ready when its declarer went - consumers hold the lease"
[ "$(kk get infraclaim "$NS-redis" -o jsonpath='{.status.appliedParams.maxmemory}')" = "111mb" ] \
  || fail "params changed when declarers vanished - consumers must never be promoted"
echo "7 ok NoDeclarer: lease held, nothing re-applied"

# --- 8. new claim with only consumers -> Pending + AwaitingDeclarer ------------
make c2 "redis" '{"module":"redis"}'
waitcond "$NS-redis-c2" "AwaitingDeclarer" "True" \
  || fail "consumer-created claim did not wait with AwaitingDeclarer"
[ "$(kk get infraclaim "$NS-redis-c2" -o jsonpath='{.status.phase}')" = "Pending" ] \
  || fail "consumer-created claim did not stay Pending"
make d3 "redis" '{"module":"redis","params":{"maxmemory":"5mb"}}'
for i in $(seq 1 8); do ph="$(kk get infraclaim "$NS-redis-c2" -o jsonpath='{.status.phase}')"; [ "$ph" = "Ready" ] && break; sleep 10; done
[ "$ph" = "Ready" ] || fail "declarer on a Pending claim did not provision it"
echo "8 ok consumer-first claim: Pending + AwaitingDeclarer, then Ready"

# --- 9. stale Updating from a crash is cleared within a tick -------------------
kk patch infraclaim "$NS-redis-c2" --type=merge --subresource=status \
  -p '{"status":{"conditions":[{"type":"Updating","status":"True","reason":"stale"}]}}' >/dev/null \
  || fail "could not seed the stale Updating condition"
waitcond "$NS-redis-c2" "Updating" "False" || fail "stale Updating not reverted in one tick"
echo "9 ok stale Updating recovered"
echo "PASS S26: nine resolution/contract/flow groups asserted against the stub"
