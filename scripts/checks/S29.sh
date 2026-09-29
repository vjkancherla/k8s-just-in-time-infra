#!/usr/bin/env bash
# S29 - The gate: design verification table U1-U13 against the live stack.
# Assertions verbatim from docs/designs/declarers-and-consumers.md §Verification.
# "One tick" = one 30s resync + one runner call; the script waits up to 8 ticks.
# Precondition: make demo-up (and for U12/U13 the test stack: make test-up).
# The final two checks delete a namespace and scale tenants; the trap restores.
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }

# Bodied kubectl: a dead API server cannot hang the checkpoint or its cleanup trap.
kk() { kubectl --request-timeout=5s "$@"; }

cleanup() { rc=$?; set +e
  docker start jit-runner >/dev/null 2>&1
  kk scale deploy/jit-controller -n default --replicas=1 >/dev/null 2>&1
  # Restore the S28 tenant shape: vote and worker are the declarers, so their
  # annotations keep the `params` key (a missing key would make them consumers).
  kk annotate deploy voting-app-vote -n voting-a --overwrite \
    jit.infra/redis='{"module":"redis","moduleVersion":"v1","params":{},"softDeleteTTL":"10m"}' >/dev/null 2>&1
  kk annotate deploy voting-app-worker -n voting-a --overwrite \
    jit.infra/postgres='{"module":"postgres","moduleVersion":"v1","params":{},"softDeleteTTL":"10m"}' >/dev/null 2>&1
  kk scale deploy voting-app-vote voting-app-worker voting-app-result \
    -n voting-a --replicas=1 >/dev/null 2>&1
  kk set env deploy voting-app-vote -n voting-a ALLOW_MULTIPLE_VOTES=true >/dev/null 2>&1
  kk delete ns voting-c --ignore-not-found >/dev/null 2>&1
  exit "$rc"; }
trap cleanup EXIT

jqf() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)"; }
# make state can die before it prints a document (e.g. an untracked deploy/.env
# missing, or no cluster at all): an empty stdout makes json.load raise, which
# under set -e exits with a bare traceback. Read it into a variable with the
# failures consumed, so a bad document reaches the readable fail() below.
state_json="$(make state 2>/dev/null || true)"
cluster_up="$(printf '%s' "$state_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("up") is True)' 2>/dev/null || true)"
[ "$cluster_up" = "True" ] || fail "make state did not report up=True (got '$cluster_up') - run 'make demo-up' before this checkpoint"
if ! kk get infraclaim voting-a-redis -n voting-a >/dev/null 2>&1 \
   || ! kk get infraclaim voting-a-postgres -n voting-a >/dev/null 2>&1; then
  fail "the voting-a claims are missing - deploy the demo first"
fi

ph() { kk get infraclaim "voting-a-$1" -n voting-a -o jsonpath='{.status.phase}' 2>/dev/null; }
cond() { kk get infraclaim "voting-a-$1" -n voting-a -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
cs={c['type']:c['status'] for c in (d['status'].get('conditions') or [])}
print(cs.get('$2','Absent'))"; }
condmsg() { kk get infraclaim "voting-a-$1" -n voting-a -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for c in d['status'].get('conditions') or []:
  if c['type']=='$2': print(c.get('message','')); break"; }
field() { kk get infraclaim "voting-a-$1" -n voting-a -o "jsonpath=$2" 2>/dev/null; }
tick() { # tick <seconds> <test-cmd>  -> retries the cmd until it succeeds or timeout
  for i in $(seq 1 9); do "$@" >/dev/null 2>&1 && return 0; sleep 12; done; return 1; }
redis_c() { docker ps --format '{{.Names}}' | grep -x 'voting-a-redis-redis'; }
pg_c()   { docker ps --format '{{.Names}}' | grep -x 'voting-a-postgres-postgres'; }
posts()  { docker logs jit-runner 2>&1 | grep -c 'POST /v1/runs' || true; }

# ================================================================== U1 redis maxmemory
posts0="$(posts)" 
kk annotate deploy voting-app-vote -n voting-a --overwrite \
  jit.infra/redis='{"module":"redis","moduleVersion":"v1","softDeleteTTL":"10m","params":{"maxmemory":"128mb"}}' >/dev/null \
  || fail "U1: could not annotate the redis declarer"
u1check() { docker exec "$(redis_c)" redis-cli CONFIG GET maxmemory 2>/dev/null | grep -qx "134217728"; }
tick u1check || fail "U1: redis did not take --maxmemory 128mb within one tick"
[ "$(field redis '{.status.appliedParams.maxmemory}')" = "128mb" ] \
  || fail "U1: appliedParams.maxmemory not $(field redis '{.status.appliedParams.maxmemory}')"
[ "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(redis_c)")" = "$(kk get infraclaim voting-a-redis -n voting-a -o jsonpath='{.status.allocatedIP}')" ] \
  || fail "U1: the redis container moved off its allocated IP"
echo "U1 ok: maxmemory 128mb applied, IP unchanged"

# ================================================================== U2 postgres add analytics in place
pgid0="$(docker inspect -f '{{.Id}}' "$(pg_c)")"
secret_keys0="$(kk get secret jit-postgres -n voting-a -o json 2>/dev/null)"
[ -n "$secret_keys0" ] && echo "$secret_keys0" >/tmp/s29-secret0.json
keys0="$(echo "$secret_keys0" | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin)["data"]))')"
kk annotate deploy voting-app-worker -n voting-a --overwrite \
  jit.infra/postgres='{"module":"postgres","moduleVersion":"v1","softDeleteTTL":"10m","params":{"databases":["voting","analytics"]}}' >/dev/null \
  || fail "U2: could not annotate the postgres declarer"
u2check() { docker exec "$(pg_c)" psql -U postgres -l 2>/dev/null | grep -qw analytics; }
tick u2check || fail "U2: analytics not created within one tick"
[ "$(docker inspect -f '{{.Id}}' "$(pg_c)")" = "$pgid0" ] \
  || fail "U2: adding a database replaced the postgres container - databases are in-place"
kk get secret jit-postgres -n voting-a -o json | python3 -c 'import sys,json;print(",".join(sorted(json.load(sys.stdin)["data"])))' | grep -q service_url_analytics \
  || fail "U2: service_url_analytics not added to jit-postgres"
# exact-bytes check for every key that existed before:
for k in $(echo "$keys0"); do
  kk get secret jit-postgres -n voting-a -o "jsonpath={.data.$k}" \
    | grep -qx "$(python3 -c "import json;print(json.load(open('/tmp/s29-secret0.json'))['data']['$k'])")" \
    || fail "U2: existing Secret key $k changed value"
done
echo "U2 ok analytics created in place, container kept, service_url_analytics added, keys unchanged"

# ================================================================== U3 consumer-only edit
posts0="$(posts)"
redis_c0="$(docker inspect -f '{{.Id}}' "$(redis_c)")"
kk annotate deploy voting-app-worker -n voting-a --overwrite \
  jit.infra/redis='{"module":"redis","moduleVersion":"v1","softDeleteTTL":"20m"}' >/dev/null \
  || fail "U3: could not annotate the redis consumer"
posts0="$(posts)"; sleep 32
posts1="$(posts)"
redis_c1="$(docker inspect -f '{{.Id}}' "$(redis_c)")"
[ "$posts1" = "$posts0" ] || fail "U3: a consumer-only edit triggered a runner call"
[ "$redis_c1" = "$redis_c0" ] || fail "U3: a consumer-only edit replaced the container"
echo "U3 ok consumer edit: no runner call, container untouched"

# ================================================================== U4 consumer declares different params
sleep 20
kk annotate deploy voting-app-result -n voting-a --overwrite \
  jit.infra/postgres='{"module":"postgres","softDeleteTTL":"10m","params":{"databases":["other"]}}' >/dev/null \
  || fail "U4: could not annotate result"
u4check() { [ "$(cond postgres ParamsConflict)" = "True" ]; }
tick u4check || fail "U4: ParamsConflict not set by a disagreeing consumer-turned-declarer"
msg="$(kk get infraclaim voting-a-postgres -n voting-a -o json 2>/dev/null | python3 -c 'import sys,json;print([c.get("message","") for c in json.load(sys.stdin)["status"].get("conditions") or [] if c["type"]=="ParamsConflict"][0])')"
echo "$msg" | grep -q voting-app-worker || fail "U4: ParamsConflict does not name worker as declarer"
echo "$msg" | grep -q voting-app-result || fail "U4: ParamsConflict does not name result as declarer"
kk annotate deploy voting-app-result -n voting-a --overwrite \
  jit.infra/postgres='{"module":"postgres","softDeleteTTL":"10m"}' >/dev/null || true
pgid1="$(docker inspect -f '{{.Id}}' "$(pg_c)")"
[ "$pgid1" = "$pgid0" ] || fail "U4: the conflict replaced a container"
echo "U4 ok consumer declares params: conflict named, locked, container kept"

# ================================================================== U7 refused: remove a database / rename postgres_db
sleep 20
posts0="$(posts)"
kk annotate deploy voting-app-worker -n voting-a --overwrite \
  jit.infra/postgres='{"module":"postgres","moduleVersion":"v1","softDeleteTTL":"10m","params":{"databases":["voting"]}}' >/dev/null \
  || fail "U7: could not annotate a database removal"
u7check() { [ "$(cond postgres UpdateRefused)" = "True" ]; }
tick u7check || fail "U7: removing a database was not refused"
msg="$(condmsg postgres UpdateRefused)"
echo "$msg" | grep -q databases || fail "U7: UpdateRefused does not name the refused key"
posts1="$(posts)"
[ "$posts1" = "$posts0" ] || fail "U7: a refused edit reached the runner"
docker exec "$(pg_c)" psql -U postgres -l 2>/dev/null | grep -qw analytics \
  || fail "U7: the refused edit removed the database anyway"
echo "U7 ok database removal refused: named key, nothing applied"

# ================================================================== U8 invalid maxmemory value
posts0="$(posts)"
kk annotate deploy voting-app-vote -n voting-a --overwrite \
  jit.infra/redis='{"module":"redis","moduleVersion":"v1","softDeleteTTL":"10m","params":{"maxmemory":"banana"}}' >/dev/null \
  || fail "U8: could not annotate the redis declarer"
u8check() { [ "$(cond redis UpdateRefused)" = "True" ]; }
tick u8check || fail "U8: an invalid maxmemory value was not refused"
posts1="$(posts)"
[ "$posts1" = "$posts0" ] || fail "U8: a refused value reached the runner"
echo "U8 ok invalid value refused, no runner call"

# ================================================================== U5 declarer deleted, consumers keep the claim
sleep 20
posts0="$(posts)"
# U5 deletes the redis declarer for real, but U9-U11 and the suite gate below still
# drive voting-app-vote; snapshot it first and restore it after the assertion (the
# EXIT trap's annotate/scale cannot bring a deleted Deployment back).
kk get deploy voting-app-vote -n voting-a -o json > /tmp/s29-vote.json \
  || fail "U5: could not snapshot the declarer before deleting it"
kk delete deploy voting-app-vote -n voting-a >/dev/null \
  || fail "U5: could not delete the redis declarer"
u5check() { [ "$(cond redis NoDeclarer)" = "True" ]; }
tick u5check || fail "U5: deleting the declarer did not set NoDeclarer"
[ "$(ph redis)" = "Ready" ] || fail "U5: claim left phase $(ph redis) - consumers hold the lease"
ap="$(field redis '{.status.appliedParams.maxmemory}')"
[ -n "$ap" ] || fail "U5: appliedParams vanished with the declarer"
posts1="$(posts)"
[ "$posts1" = "$posts0" ] || fail "U5: a declarer deletion triggered a runner call"
# Restore the declarer for U9-U11 and the gate. `kubectl apply` of the
# get-exported object, with the server-side fields stripped so the create is clean;
# its annotation is the U1 one (maxmemory 128mb), which equals appliedParams, so the
# restore makes no runner call.
python3 - <<'PY'
import json
d = json.load(open('/tmp/s29-vote.json'))
for k in ('resourceVersion', 'uid', 'creationTimestamp', 'generation',
          'managedFields', 'selfLink'):
    d.setdefault('metadata', {}).pop(k, None)
d.pop('status', None)
json.dump(d, open('/tmp/s29-vote-create.json', 'w'))
PY
kk apply -f /tmp/s29-vote-create.json >/dev/null \
  || fail "U5: could not restore the redis declarer after the deletion assertion"
echo "U5 ok declarer gone: Ready held, NoDeclarer set, nothing re-applied"

# ================================================================== U6 consumer-first namespace
kk create ns voting-c >/dev/null 2>&1 || fail "U6: could not create the test namespace"
cat <<EOF | kk apply -f - >/dev/null || fail "U6: consumer deployment failed"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consumer-first
  namespace: voting-c
  annotations:
    jit.infra/redis: '{"module":"redis","softDeleteTTL":"10m"}'
  labels: {app: consumer-first}
spec:
  replicas: 1
  selector: {matchLabels: {app: consumer-first}}
  template:
    metadata: {labels: {app: consumer-first}}
    spec:
      containers: [{name: pause, image: public.ecr.aws/aws-cli/aws-cli:latest, command: ["sh","-c","sleep 600"]}]
EOF
u6check() { kk get infraclaim voting-c-redis -n voting-c -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx Pending; }
tick u6check || fail "U6: consumer-created claim did not stay Pending"
[ "$(kk get infraclaim voting-c-redis -n voting-c -o jsonpath='{.status.phase}')" = "Pending" ] || true
condc="Absent"
for i in $(seq 1 9); do
  condc="$(kk get infraclaim voting-c-redis -n voting-c -o json 2>/dev/null | python3 -c 'import sys,json;print({c["type"]:c["status"] for c in json.load(sys.stdin)["status"].get("conditions") or []}.get("AwaitingDeclarer","Absent"))')"
  [ "$condc" = "True" ] && break; sleep 12
done
[ "$condc" = "True" ] || fail "U6: consumer-created claim lacks AwaitingDeclarer"
cat <<EOF | kk apply -f - >/dev/null || fail "U6: declarer deployment failed"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: declarer-comes
  namespace: voting-c
  annotations:
    jit.infra/redis: '{"module":"redis","params":{},"softDeleteTTL":"10m"}'
  labels: {app: declarer-comes}
spec:
  replicas: 1
  selector: {matchLabels: {app: declarer-comes}}
  template:
    metadata: {labels: {app: declarer-comes}}
    spec:
      containers: [{name: pause, image: public.ecr.aws/aws-cli/aws-cli:latest, command: ["sh","-c","sleep 600"]}]
EOF
u6bcheck() { kk get infraclaim voting-c-redis -n voting-c -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx Ready; }
tick u6bcheck || fail "U6: claim never went Ready after the declarer appeared"
echo "U6 ok consumer-first namespace: Pending + AwaitingDeclarer, Ready once declared"

# ================================================================== U9 runner down: failure isolation and retry-on-change
docker stop jit-runner >/dev/null || fail "U9: could not stop the runner"
posts0="$(posts)"
kk annotate deploy voting-app-vote -n voting-a --overwrite \
  jit.infra/redis='{"module":"redis","moduleVersion":"v1","softDeleteTTL":"10m","params":{"maxmemory":"200mb"}}' >/dev/null \
  || fail "U9: could not annotate the redis declarer with a change"
u9cond=""
for i in $(seq 1 9); do
  u9cond="$(cond redis UpdateFailed)"
  [ "$u9cond" = "True" ] && break; sleep 12
done
u9cond="$(cond redis UpdateFailed)"
[ "$u9cond" = "True" ] || fail "U9: runner down did not set UpdateFailed"
[ "$(ph redis)" = "Ready" ] || fail "U9: failed update left phase $(ph redis) - the design keeps Ready"
ap="$(field redis '{.status.appliedParams.maxmemory}')"
[ "$ap" = "128mb" ] || fail "U9: the failed update moved appliedParams from 128mb to $ap"
# two more ticks must not add attempts: the hash gates the retry
hash0="$(field redis '{.status.attemptedParamsHash}')"
for i in 1 2; do sleep 32; done
hash1="$(field redis '{.status.attemptedParamsHash}')"
[ "$hash1" = "$hash0" ] || fail "U9: the failed update was retried without the params changing"
docker start jit-runner >/dev/null || fail "U9: could not restart the runner"
sleep 5
kk annotate deploy voting-app-vote -n voting-a --overwrite \
  jit.infra/redis='{"module":"redis","moduleVersion":"v1","softDeleteTTL":"10m","params":{"maxmemory":"222mb"}}' >/dev/null \
  || fail "U9: could not re-edit the redis declarer"
u9bcheck() { [ "$(field redis '{.status.appliedParams.maxmemory}')" = "222mb" ]; }
tick u9bcheck || fail "U9: a changed value did not retry and converge"
echo "U9 ok runner down: Ready kept, one attempt, and convergence after re-edit"

# ================================================================== U10 controller killed mid-apply
posts0="$(posts)"
kk annotate deploy voting-app-vote -n voting-a --overwrite \
  jit.infra/redis='{"module":"redis","moduleVersion":"v1","softDeleteTTL":"10m","params":{"maxmemory":"233mb"}}' >/dev/null \
  || fail "U10: could not annotate"
kk scale deploy/jit-controller -n default --replicas=0 >/dev/null || fail "U10: could not kill the controller"
sleep 40
kk scale deploy/jit-controller -n default --replicas=1 >/dev/null
u10check() { [ "$(cond redis Updating)" != "True" ]; }
tick u10check || fail "U10: stale Updating not cleared within one tick of the restart"
u10bcheck() { [ "$(field redis '{.status.appliedParams.maxmemory}')" = "233mb" ]; }
tick u10bcheck || fail "U10: the interrupted update did not re-evaluate and converge"
echo "U10 ok crash recovered: Updating cleared, update converged"

# ================================================================== U11 controller upgraded over Ready claims
# remove the backfill, upgrade, and prove the first resync neither calls the
# runner nor touchies containers
posts0="$(posts)"
redis_c0="$(docker inspect -f '{{.Id}}' "$(redis_c)")"
pgid0="$(docker inspect -f '{{.Id}}' "$(pg_c)")"
kk patch infraclaim voting-a-redis -n voting-a --type=json -p='[{"op":"remove","path":"/status/appliedParams"}]' >/dev/null 2>&1 \
  || fail "U11: could not strip appliedParams for the backfill test"
kk rollout restart deploy/jit-controller -n default >/dev/null || fail "U11: could not restart the controller"
u11check() { kk get infraclaim voting-a-redis -n voting-a -o json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
s=d["status"].get("appliedParams") or {}
sp=(d.get("spec") or {}).get("params") or {}
sys.exit(0 if s.get("maxmemory")=="233mb" else 1)'; }
tick u11check || fail "U11: appliedParams not backfilled after the upgrade"
[ "$(docker inspect -f '{{.Id}}' "$(redis_c)")" = "$redis_c0" ] \
  || fail "U11: the controller upgrade replaced the redis container"
echo "U11 ok backfill: adopted spec.params without a runner call, no container churn"

# ================================================================== U13 two consumers, different TTL (voting-b)
kk get infraclaim voting-b-postgres -n voting-b >/dev/null 2>&1 \
  || fail "U13: voting-b claims missing - run 'make test-up' before this checkpoint"
posts0="$(posts)"
kk annotate deploy voting-app-vote -n voting-b --overwrite \
  jit.infra/redis='{"module":"redis","softDeleteTTL":"45m"}' >/dev/null \
  || fail "U13: could not set a consumer TTL in voting-b"
u13check() { ttl="$(kk get infraclaim voting-b-postgres -n voting-b -o jsonpath='{.spec.softDeleteTTL}')"; [ "$ttl" = "45m" ] || true; ttl="$(kk get infraclaim voting-b-redis -n voting-b -o jsonpath='{.spec.softDeleteTTL}')"; [ -n "$ttl" ] && [ "$ttl" = "45m" ]; }
tick u13check || fail "U13: spec.softDeleteTTL is not the maximum (45m) across references"
posts1="$(posts)"; sleep 32
[ "$posts1" = "$posts0" ] || fail "U13: a TTL-only patch triggered a runner call"
echo "U13 ok TTL maximum taken from a consumer, no runner call"

# =============== the gate's suite survival (build-plan S29, before U12 deletes voting-a)
# The R-suite and the J-suite must both survive everything Stage H changed. Run them
# while voting-a is still alive (U12 destroys it below). `.workflow` lives at the repo
# root or under app/ depending on the target; both are accepted, and a stale artifact is
# removed first so it cannot pass the gate. Never trust `make verify`'s exit code for the
# count - verify.sh exits 0 even when checks fail - so parse the summary line.
# demo-up leaves ALLOW_MULTIPLE_VOTES=true for the click-the-demo mode; R3 asserts
# the one-vote-per-browser behaviour, so disable it for the R-suite and restore it
# afterwards (the R-suite is what must survive, not the demo toggle).
kk set env deploy/voting-app-vote -n voting-a ALLOW_MULTIPLE_VOTES=false >/dev/null \
  || fail "the S29 gate: could not disable demo mode for the R-suite"
kk rollout status deploy/voting-app-vote -n voting-a --timeout=180s >/dev/null \
  || fail "the S29 gate: vote did not roll after disabling demo mode"
rm -f .workflow/verify.md app/.workflow/verify.md
if ! make verify NS=voting-a >/tmp/s29-verify.log 2>&1; then
  tail -5 /tmp/s29-verify.log | sed 's/^/  /'
  fail "the S29 gate: 'make verify NS=voting-a' failed - the R-suite broke under Stage H"
fi
verify_md="$(for f in .workflow/verify.md app/.workflow/verify.md; do [ -f "$f" ] && { echo "$f"; break; }; done)"
[ -n "$verify_md" ] || fail "the S29 gate: make verify wrote no .workflow/verify.md"
verify_sum="$(grep -E '^===== [0-9]+ PASS, [0-9]+ FAIL =====$' "$verify_md" | tail -1 || true)"
[ "$verify_sum" = "===== 17 PASS, 0 FAIL =====" ] \
  || fail "the S29 gate: make verify did not report '17 PASS, 0 FAIL' (got '${verify_sum:-no summary line}') - see $verify_md"
echo "gate ok: make verify NS=voting-a reports 17 PASS, 0 FAIL"
kk set env deploy/voting-app-vote -n voting-a ALLOW_MULTIPLE_VOTES=true >/dev/null 2>&1 || true
kk rollout status deploy/voting-app-vote -n voting-a --timeout=180s >/dev/null 2>&1 || true

rm -f .workflow/verify-jit.md app/.workflow/verify-jit.md
if ! make jit-verify >/tmp/s29-jit.log 2>&1; then
  tail -5 /tmp/s29-jit.log | sed 's/^/  /'
  fail "the S29 gate: 'make jit-verify' failed - the J-suite broke under Stage H"
fi
jit_md="$(for f in .workflow/verify-jit.md app/.workflow/verify-jit.md; do [ -f "$f" ] && { echo "$f"; break; }; done)"
[ -n "$jit_md" ] || fail "the S29 gate: make jit-verify wrote no .workflow/verify-jit.md"
for j in $(seq 1 11); do
  grep -qE "^J${j}[[:space:]]+PASS" "$jit_md" \
    || fail "the S29 gate: J$j did not report PASS in $jit_md"
done
grep -qE '^J[0-9]+[[:space:]]+FAIL' "$jit_md" \
  && fail "the S29 gate: a J-check reported FAIL in $jit_md"
echo "gate ok: make jit-verify reports J1-J11 all PASS"

# ================================================================== U12 namespace delete after U2
kk delete ns voting-a --wait=true >/dev/null 2>&1 &
u12check() { [ -z "$(kk get ns voting-a -o name 2>/dev/null)" ]; }
tick u12check || fail "U12: namespace not fully deleted - the finalizer is wedged"
kk get ns voting-a >/dev/null 2>&1 \
  && fail "U12: namespace is still listed - the finalizer is wedged"
kk get infraclaims -n voting-a -o name 2>/dev/null | grep -q . \
  && fail "U12: claims survived the namespace"
docker ps -a --format '{{.Names}}' | grep -qx 'voting-a-postgres-postgres' \
  && fail "U12: the postgres container survived the namespace delete"
echo "U12 ok namespace delete: destroyed, finalizer released, gone"
echo "PASS S29: U1-U13 asserted live"
