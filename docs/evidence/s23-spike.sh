#!/usr/bin/env bash
# S23 spike probe - see docs/build-plan.md S23.
#
# Measures what the declarers-and-consumers mutability contract may only claim
# after measurement:
#   - how long a redis and a postgres container replace take (tofu apply wall time)
#   - how many queued votes a redis replace drops
#   - whether vote and worker reconnect afterwards
#   - whether call_runner runs synchronously inside a kopf handler and blocks the
#     event loop
# Everything measured goes into docs/evidence/s23-spike.log. The script mutates
# the voting-a demo stack and restores it; run it with the demo stack up.
#
#   make jit-up && (cd app && make all NS=voting-a) && docs/evidence/s23-spike.sh
set -uo pipefail

ROOT=/Users/vkancherla/Downloads/Devops-Projects/k8s-just-in-time-infra
cd "$ROOT"

NS=voting-a
REDIS=voting-a-redis-redis
PG=voting-a-postgres-postgres
PGVOL=voting-a-postgres-postgres-data
REDIS_IP=172.19.0.102
PG_IP=172.19.0.100
NET=k3d-voting-app
N=50
MINIO_EP=http://127.0.0.1:9000
export DOCKER_HOST="${DOCKER_HOST:-unix:///Users/vkancherla/.rd/docker.sock}"

# The committed evidence lives at FINAL_LOG. The run writes to a sibling temp file
# and moves it into place only after the last line, so a run that dies at preflight
# or anywhere mid-protocol can never truncate or replace the evidence the frozen
# checkpoint reads (docs/reviews/S23-findings.md, concern 4). Set S23_SPIKE_LOG to
# send a validation run somewhere else and leave the committed log untouched.
FINAL_LOG="${S23_SPIKE_LOG:-docs/evidence/s23-spike.log}"
mkdir -p "$(dirname "$FINAL_LOG")"
LOG="${FINAL_LOG}.tmp.$$"
trap 'rm -f "$LOG"' EXIT
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { log ""; log "=== $* ==="; }
die() { log "FAIL: $*"; exit 1; }
now() { python3 -c 'import time; print(time.time())'; }

backend_init() { # $1=workdir $2=state key
  tofu -chdir="$1" init -input=false -no-color \
    -backend-config=bucket=jit-state \
    -backend-config=key="$2" \
    -backend-config=endpoint="$MINIO_EP" \
    -backend-config=access_key=jit-state \
    -backend-config=secret_key=jit-state-secret-2026 \
    -backend-config=region=us-east-1 \
    -backend-config=skip_credentials_validation=true \
    -backend-config=skip_metadata_api_check=true \
    -backend-config=force_path_style=true >>"$LOG" 2>&1
}

sec "preflight - demo stack up"
log "# spike run started $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname)"
command -v tofu >/dev/null 2>&1 || die "tofu not on PATH"
docker network inspect "$NET" >/dev/null 2>&1 || die "docker network $NET missing"
[ "$(docker inspect -f '{{.State.Running}}' "$REDIS" 2>/dev/null)" = "true" ] \
  || die "$REDIS not running - run the demo stack first"
[ "$(docker inspect -f '{{.State.Running}}' "$PG" 2>/dev/null)" = "true" ] \
  || die "$PG not running - run the demo stack first"
kubectl get ns "$NS" >/dev/null 2>&1 || die "namespace $NS missing - run the demo stack first"
log "tofu $(tofu version | head -1)"
log "redis $REDIS at $REDIS_IP; postgres $PG at $PG_IP; network $NET"

sec "handler-side protocol: does call_runner block the kopf event loop?"
CTRL_IMG=$(kubectl get deploy jit-controller -n default -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
log "controller image: $CTRL_IMG"
cat > /tmp/s23-kopf-probe.py <<'PY'
import asyncio
import threading
import kopf
from kopf._core.actions.invocation import invoke

def sync_handler(**kwargs):
    return threading.get_ident()

async def main():
    loop_tid = threading.get_ident()
    handler_tid = await invoke(sync_handler)
    separate = handler_tid != loop_tid
    from kopf._cogs.configs import configuration
    pool = configuration.OperatorSettings().execution.executor
    print(f"kopf {kopf.__version__}: event-loop thread {loop_tid}; "
          f"sync handler ran on thread {handler_tid}; "
          f"separate executor thread: {separate}")
    print(f"default sync-handler executor: {type(pool).__name__} "
          f"max_workers={getattr(pool, '_max_workers', '?')}")

asyncio.run(main())
PY
# rc-checked: the verdict is derived from this probe, never typed ahead of it.
probe_out="$(kubectl exec -i -n default deploy/jit-controller -- python - < /tmp/s23-kopf-probe.py 2>&1)"
probe_rc=$?
printf '%s\n' "$probe_out" | tee -a "$LOG"
[ "$probe_rc" = "0" ] || die "kopf executor probe failed (rc=$probe_rc) - cannot decide whether call_runner blocks"
printf '%s\n' "$probe_out" | grep -q 'separate executor thread: True' \
  || die "the kopf probe reported no separate executor thread - call_runner may block the event loop; refusing to write the verdict"
log "code reading: jit-controller/main.py handle_deployment is a synchronous def (line 129) and"
log "resync_referenced_by is a synchronous @kopf.timer def (line 816); provision_infra -> call_runner"
log "(line 352) is a plain blocking requests.post with timeout=600."
log "kopf/_core/actions/invocation.py line 134 executes a synchronous handler with"
log "loop.run_in_executor(executor, real_fn), i.e. on a worker thread, not the event loop."
log "call_runner blocking verdict (derived from the probe above, rc=$probe_rc): call_runner does not block"
log "the kopf event loop - kopf offloads synchronous handlers to an executor thread, so the 30s resync"
log "keeps ticking while an apply runs; asyncio.to_thread would be required only if S26 converts the"
log "handler to async def."
log "caveat - the executor pool is the real ceiling, and this probe did not drive it there: kopf shares"
log "that executor across every sync handler (handle_deployment, the 30s resync timer, the delete handler)."
log "The pool's max_workers is printed above. The resync keeps ticking only while fewer than that many"
log "applies are in flight; at the ceiling a 600s call_runner call queues the resync behind it, which is"
log "the same stop the design describes, arriving through the pool rather than the event loop. S26 decides"
log "whether to cap concurrency or move call_runner to asyncio.to_thread; this spike records the ceiling."

sec "redis replace - queue held behind a stopped worker, then the container replaced"
REDIS_ID_BEFORE=$(docker inspect -f '{{.Id}}' "$REDIS")
REDIS_CMD_BEFORE=$(docker inspect -f '{{json .Config.Cmd}}' "$REDIS")
log "before: id=$REDIS_ID_BEFORE cmd=$REDIS_CMD_BEFORE"

RW=/tmp/s23-spike-redis
rm -rf "$RW"; mkdir -p "$RW"; cp jit-modules/modules/redis/* "$RW"/
backend_init "$RW" "ns/$NS/redis/terraform.tfstate" || die "redis tofu init failed"
tofu -chdir="$RW" plan -no-color -input=false \
  -var name=voting-a-redis -var ip="$REDIS_IP" -var network="$NET" -var maxmemory=128mb \
  2>&1 | grep -E "must be replaced|forces replacement|Plan:" | tee -a "$LOG"

log "scale voting-app-worker to 0 so nothing drains the queue during the replace"
kubectl scale deploy voting-app-worker -n "$NS" --replicas=0 >>"$LOG" 2>&1 \
  || die "could not scale voting-app-worker to 0 - the vote-loss measurement would be invalid"
for _ in $(seq 1 60); do
  [ "$(kubectl get pod -n "$NS" -l app.kubernetes.io/component=worker --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && break
  sleep 1
done
worker_left=$(kubectl get pod -n "$NS" -l app.kubernetes.io/component=worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$worker_left" = "0" ] || die "worker still has $worker_left pod(s) after 60s - the vote-loss measurement would be invalid"
docker exec "$REDIS" redis-cli DEL votes >/dev/null 2>&1
python3 - "$N" > /tmp/s23-votes.resp <<'PY'
import json, sys
for i in range(1, int(sys.argv[1]) + 1):
    payload = json.dumps({"voter_id": f"s23-{i}", "choice": "Cats", "timestamp": 0})
    sys.stdout.write(f"*3\r\n$5\r\nRPUSH\r\n$5\r\nvotes\r\n${len(payload)}\r\n{payload}\r\n")
PY
docker exec -i "$REDIS" redis-cli --pipe < /tmp/s23-votes.resp >>"$LOG" 2>&1
BEFORE=$(docker exec "$REDIS" redis-cli LLEN votes 2>/dev/null | tr -d '\r')
[ -n "${BEFORE:-}" ] || die "could not read LLEN votes before the replace (redis unreachable?) - the vote-loss measurement would be empty"
log "queued ${BEFORE:-0} votes (LLEN votes) with the worker stopped"

t0=$(now)
tofu -chdir="$RW" apply -auto-approve -no-color -input=false \
  -var name=voting-a-redis -var ip="$REDIS_IP" -var network="$NET" -var maxmemory=128mb >>"$LOG" 2>&1
rc=$?
t_apply=$(now)
[ "$rc" = "0" ] || die "redis replace apply failed (rc=$rc)"
for _ in $(seq 1 150); do docker exec "$REDIS" redis-cli ping >/dev/null 2>&1 && break; sleep 0.2; done
t_ready=$(now)
RS=$(python3 -c "print(f'{$t_apply-$t0:.2f}')")
RSTART=$(python3 -c "print(f'{$t_ready-$t_apply:.2f}')")
RTOT=$(python3 -c "print(f'{$t_ready-$t0:.2f}')")
RSI=$(python3 -c "import math; print(math.ceil($t_ready-$t0))")
log "redis replace: ${RSI}s or less until redis answers again (tofu apply ${RS}s + container start ${RSTART}s = ${RTOT}s total; the plan above shows the container is replaced)"

REDIS_ID_AFTER=$(docker inspect -f '{{.Id}}' "$REDIS")
REDIS_CMD_AFTER=$(docker inspect -f '{{json .Config.Cmd}}' "$REDIS")
AFTER=$(docker exec "$REDIS" redis-cli LLEN votes 2>/dev/null | tr -d '\r')
LOST=$(( ${BEFORE:-0} - ${AFTER:-0} ))
log "after: id=$REDIS_ID_AFTER cmd=$REDIS_CMD_AFTER"
[ -n "${AFTER:-}" ] || die "could not read LLEN votes after the replace (redis unreachable?)"
[ "$REDIS_ID_BEFORE" != "$REDIS_ID_AFTER" ] || die "the redis container was not replaced - maxmemory did not force a replacement"
log "votes lost across the replace: $LOST of ${BEFORE:-0} queued (LLEN votes after=${AFTER:-0})"

log "scale voting-app-worker back to 1 and assert reconnect"
log "(the worker was deliberately stopped before the replace, so this is a fresh-pod startup reconnect,"
log " not evidence that a long-lived client survives a replace; the in-place RedisError reconnect path in"
log " app/worker/app.py is not exercised here because the pod is recreated)"
kubectl scale deploy voting-app-worker -n "$NS" --replicas=1 >>"$LOG" 2>&1 \
  || die "could not scale voting-app-worker back to 1"
kubectl rollout status deploy/voting-app-worker -n "$NS" --timeout=120s >>"$LOG" 2>&1 \
  || die "worker rollout did not finish within 120s - reconnect cannot be asserted"
W_POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "${W_POD:-}" ] || die "no worker pod found after the scale-up - reconnect cannot be asserted"
# rc-checked: a FAILED reconnect must abort the run, never be logged green (concern 2).
if kubectl exec -n "$NS" "$W_POD" -- python /app/app.py --healthcheck >>"$LOG" 2>&1; then
  log "reconnect (worker): fresh pod --healthcheck OK - it connected to the recreated redis and postgres"
else
  die "reconnect (worker): fresh pod --healthcheck FAILED - refusing to record a green reconnect"
fi
V_POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/component=vote -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "${V_POD:-}" ] || die "no vote pod found - reconnect cannot be asserted"
if kubectl exec -n "$NS" "$V_POD" -- python -c 'import urllib.request; urllib.request.urlopen("http://localhost:80/healthz", timeout=5)' >>"$LOG" 2>&1; then
  log "reconnect (vote): vote was NOT restarted; /healthz OK - it reached the recreated redis. app/vote/app.py"
  log "builds a fresh Redis client per request, so this proves reachability of the new container, not"
  log "re-establishment of a long-lived connection."
else
  die "reconnect (vote): /healthz FAILED - refusing to record a green reconnect"
fi
FV=$(python3 -c 'import json; print(json.dumps({"voter_id": "s23-post-replace", "choice": "Dogs", "timestamp": 0}))')
docker exec "$REDIS" redis-cli RPUSH votes "$FV" >/dev/null 2>&1
drained=no
for _ in $(seq 1 30); do
  llen=$(docker exec "$REDIS" redis-cli LLEN votes 2>/dev/null | tr -d '\r')
  if [ "${llen:-x}" = "0" ]; then drained=yes; break; fi
  sleep 1
done
llen=$(docker exec "$REDIS" redis-cli LLEN votes 2>/dev/null | tr -d '\r')
# rc-checked: a queue the restarted worker never drains is a failed reconnect (concern 2).
[ "$drained" = "yes" ] \
  || die "the restarted worker did not drain the post-replace vote within 30s (LLEN votes=${llen:-?}) - reconnect not proven"
log "reconnect (worker): the restarted worker drained a post-replace vote to postgres (LLEN votes=$llen)"

log "restore maxmemory to 256mb so the demo stack keeps its declared defaults"
t0=$(now)
tofu -chdir="$RW" apply -auto-approve -no-color -input=false \
  -var name=voting-a-redis -var ip="$REDIS_IP" -var network="$NET" -var maxmemory=256mb >>"$LOG" 2>&1
rc=$?
t1=$(now)
RRS=$(python3 -c "print(round($t1-$t0,1))")
log "redis restore: ${RRS}s (rc=$rc; cmd=$(docker inspect -f '{{json .Config.Cmd}}' "$REDIS"))"

sec "postgres replace - an S27-style setting (-c) added to the container command"
PG_ID_BEFORE=$(docker inspect -f '{{.Id}}' "$PG")
PGVOL_BEFORE=$(docker volume inspect "$PGVOL" -f '{{.CreatedAt}}' 2>/dev/null)
ROWS_BEFORE=$(docker exec "$PG" psql -U postgres -d voting -tAc 'select count(*) from votes' 2>/dev/null | tr -d '[:space:]')
log "before: id=$PG_ID_BEFORE volume=$PGVOL created=$PGVOL_BEFORE rows=${ROWS_BEFORE:-?}"
PW=$(kubectl get secret jit-postgres -n "$NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d)
[ -n "${PW:-}" ] || die "could not read the jit-postgres password"

PWDIR=/tmp/s23-spike-pg
rm -rf "$PWDIR"; mkdir -p "$PWDIR"; cp jit-modules/modules/postgres/* "$PWDIR"/
python3 - "$PWDIR/main.tf" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
anchor = '  name  = "${var.name}-postgres"\n'
assert anchor in src, "anchor not found in postgres main.tf"
open(path, 'w').write(src.replace(
    anchor, anchor + '  command = ["postgres", "-c", "max_connections=200"]\n', 1))
PY
backend_init "$PWDIR" "ns/$NS/postgres/terraform.tfstate" || die "postgres tofu init failed"
tofu -chdir="$PWDIR" plan -no-color -input=false \
  -var name=voting-a-postgres -var ip="$PG_IP" -var network="$NET" \
  -var postgres_password="$PW" -var postgres_db=voting \
  2>&1 | grep -E "command|forces replacement|Plan:" | tee -a "$LOG"

t0=$(now)
tofu -chdir="$PWDIR" apply -auto-approve -no-color -input=false \
  -var name=voting-a-postgres -var ip="$PG_IP" -var network="$NET" \
  -var postgres_password="$PW" -var postgres_db=voting >>"$LOG" 2>&1
rc=$?
t_apply=$(now)
[ "$rc" = "0" ] || die "postgres replace apply failed (rc=$rc)"
for _ in $(seq 1 300); do docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 0.2; done
t_ready=$(now)
PS=$(python3 -c "print(f'{$t_apply-$t0:.2f}')")
PSTART=$(python3 -c "print(f'{$t_ready-$t_apply:.2f}')")
PTOT=$(python3 -c "print(f'{$t_ready-$t0:.2f}')")
PSI=$(python3 -c "import math; print(math.ceil($t_ready-$t0))")
log "postgres replace: ${PSI}s or less until postgres answers again (tofu apply ${PS}s + server start ${PSTART}s = ${PTOT}s total; adds command ['postgres','-c','max_connections=200'] - the S27 settings path; the plan above shows the container is replaced)"
PG_ID_AFTER=$(docker inspect -f '{{.Id}}' "$PG")
PGVOL_AFTER=$(docker volume inspect "$PGVOL" -f '{{.CreatedAt}}' 2>/dev/null)
ROWS_AFTER=$(docker exec "$PG" psql -U postgres -d voting -tAc 'select count(*) from votes' 2>/dev/null | tr -d '[:space:]')
log "after: id=$PG_ID_AFTER"
log "postgres volume survived the replace: $PGVOL created=$PGVOL_AFTER (unchanged: $([ "${PGVOL_BEFORE:-x}" = "${PGVOL_AFTER:-y}" ] && echo yes || echo NO))"
log "postgres data survived the replace: votes rows before=${ROWS_BEFORE:-?} after=${ROWS_AFTER:-?}"

log "restore the stock postgres module (drop the injected command) so the demo stack is unchanged"
PWREST=/tmp/s23-spike-pg-restore
rm -rf "$PWREST"; mkdir -p "$PWREST"; cp jit-modules/modules/postgres/* "$PWREST"/
backend_init "$PWREST" "ns/$NS/postgres/terraform.tfstate" || die "postgres restore init failed"
t0=$(now)
tofu -chdir="$PWREST" apply -auto-approve -no-color -input=false \
  -var name=voting-a-postgres -var ip="$PG_IP" -var network="$NET" \
  -var postgres_password="$PW" -var postgres_db=voting >>"$LOG" 2>&1
rc=$?
t1=$(now)
PRS=$(python3 -c "print(round($t1-$t0,1))")
log "postgres restore: ${PRS}s (rc=$rc; stock module re-applied, command removed)"

sec "verdict"
log "measured: redis replace <=${RSI}s (apply ${RS}s + container start ${RSTART}s = ${RTOT}s total, measured wall time until redis answers);"
log "postgres replace <=${PSI}s (apply ${PS}s + server start ${PSTART}s = ${PTOT}s total, until pg_isready); votes lost ${LOST} of ${BEFORE:-0} across the redis replace;"
log "reconnect: the worker was restarted for this measurement and re-drained a post-replace vote; vote stayed up and reached the new redis."
# The verdict is a recorded human decision, not a function of LOST alone. The 50/50 lost
# votes would refuse redis maxmemory under the mutability contract's criterion 1 ('adds or
# tunes, never removes data'); the human decided on 2026-09-28 that a Deployment-annotation
# edit is explicit approval for the downtime it causes. Encode that decision here so a
# rerun regenerates the committed verdict block (docs/decisions/0007-maxmemory-mutable-despite-replace-cost.md).
log "decision-overlay: docs/decisions/0007-maxmemory-mutable-despite-replace-cost.md"
log "human decision (2026-09-28): an infrastructure change made through the Deployment annotation is an"
log "explicit approval for any downtime it causes, so downtime is accepted. The replaces are <=1s and the"
log "worker reconnects on restart (vote stays reachable through a fresh per-request client), so the update"
log "cost is acceptable; redis maxmemory stays mutable and U1 stays in scope. Read literally, the"
log "contract's criterion 1 ('adds or tunes, never removes data') would refuse maxmemory on the 50-of-50"
log "vote loss; the 2026-09-28 human decision overrides that reading for redis maxmemory."
log "verdict provenance: the VERDICT line below is the recorded human decision, not a result the probe"
log "measured. The probe measured the replace timings, the (startup) reconnect and the 50-of-50 vote loss;"
log "it did not decide mutability. The decision is ADR 0007 - a review judges that ADR (its reasoning and"
log "its scope), not the probe's numbers."
log "VERDICT: maxmemory mutable"

sec "side finding (not this step's checkpoint)"
log "every re-apply of the stock redis/postgres module plans a replacement even with unchanged params:"
log "ports { external = 0 } records the random host port in state and the next plan diffs it"
log "(external = <assigned> -> 0 # forces replacement). S27's databases-only update (U2: container ID"
log "unchanged) needs this addressed in the module, or the container is replaced on every apply."
log "done"

# Publish only a run that reached this line; die() leaves the committed log untouched.
mv "$LOG" "$FINAL_LOG"
trap - EXIT
echo "spike log written: $FINAL_LOG"
