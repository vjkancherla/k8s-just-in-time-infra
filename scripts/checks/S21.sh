#!/usr/bin/env bash
# S21 - `make timeline`: what actually happened, with a source on every event.
#
# Written before the feature exists, from the Goal in docs/build-plan.md S21, and frozen
# from here on: if this looks wrong, stop and ask - do not adjust it to match the code. It
# is expected to FAIL until S21 is implemented.
#
# It does not trust the document. Three events are re-derived from their independent
# sources - kubectl, docker inspect, and the runner's own log - and compared, so a
# timeline that reports plausible times it did not read is a FAIL.
#
# Precondition: the demo stack is up (make demo-up) for everything after the no-cluster
# assertion, which runs first precisely because it needs nothing.
set -euo pipefail

cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $1"; exit 1; }
ok()   { echo "  ok: $1"; }

# ------------------------------------------------------------- 1. it is a target
target_defined() { { make -pRrq : 2>/dev/null || true; } | grep -Eq "^$1:( |$)"; }
target_defined timeline || fail "no make target 'timeline'"

grep -qx timeline <<<"$(make -s targets 2>/dev/null)" \
  || fail "make targets does not list timeline - the console cannot read it"
ok "make timeline is defined and make targets lists it"

[ -s scripts/timeline.sh ] || fail "no scripts/timeline.sh"
ok "scripts/timeline.sh exists"

# ------------------------------------------------- 2. no cluster: up=false, exit 0
nostate="$(KUBECONFIG=/nonexistent/kubeconfig make -s timeline 2>/dev/null)" \
  || fail "make timeline exited non-zero with no cluster - the page may ask before one exists"
jq -e '.up == false' <<<"$nostate" >/dev/null \
  || fail "with no cluster the timeline must report up=false"
jq -e '.events == []' <<<"$nostate" >/dev/null \
  || fail "with no cluster the timeline must report no events"
ok "make timeline degrades to up=false instead of erroring"

# ----------------------------------------------------------- 3. it is a document
doc="$(make -s timeline 2>/dev/null)" || fail "make timeline exited non-zero"
[ -n "$doc" ] || fail "make timeline printed nothing"
jq -e 'type == "object"' <<<"$doc" >/dev/null || fail "make timeline is not one JSON object"
for k in up generatedAt t0 events; do
  jq -e --arg k "$k" 'has($k)' <<<"$doc" >/dev/null || fail "the timeline object has no '$k'"
done
jq -e '.up == true' <<<"$doc" >/dev/null \
  || fail "the timeline says up=false - run 'make demo-up' before this checkpoint"
jq -e '.events | type == "array"' <<<"$doc" >/dev/null || fail "events is not an array"
printf '%s' "$doc" > /tmp/s21.json
ok "make timeline emits one JSON object with up/generatedAt/t0/events"

# ------------------------------------------------- 4. every event is traceable
jq -e '[.events[] | select((has("t") and has("lane") and has("kind") and has("subject") and has("source")) | not)] | length == 0' \
  <<<"$doc" >/dev/null || fail "an event is missing one of t/lane/kind/subject/source"
jq -e '[.events[] | select((.source // "") == "")] | length == 0' \
  <<<"$doc" >/dev/null || fail "an event names no source - every timestamp must say where it came from"
jq -e '[.events[].lane] | unique - ["deployment","controller","runner","container","pod"] | length == 0' \
  <<<"$doc" >/dev/null || fail "an event has a lane outside deployment/controller/runner/container/pod"
jq -e '[.events[].t] as $t | ($t == ($t | sort))' <<<"$doc" >/dev/null \
  || fail "events are not sorted ascending by t"
jq -e '[.events[] | select(has("duration") or has("ms") or has("delta") or has("gap"))] | length == 0' \
  <<<"$doc" >/dev/null || fail "an event carries an interval - the timeline reads times, it does not compute gaps"
ok "every event carries t/lane/kind/subject/source, sorted, with no computed intervals"

# -------------------------------------------------- 5. it is not a vacuous document
n="$(jq '.events | length' <<<"$doc")"
[ "$n" -ge 6 ] || fail "only $n events - that is not a run's timeline"
lanes="$(jq '[.events[].lane] | unique | length' <<<"$doc")"
[ "$lanes" -ge 3 ] || fail "only $lanes lanes carry events - the join is not working"
for kind in deployment.applied container.started runner.call; do
  jq -e --arg k "$kind" '[.events[] | select(.kind == $k)] | length >= 1' <<<"$doc" >/dev/null \
    || fail "no '$kind' event - the timeline is missing a step this checkpoint cross-checks"
done
span="$(python3 - <<'PY'
import datetime as dt, json
e = json.load(open('/tmp/s21.json'))['events']
f = lambda s: dt.datetime.fromisoformat(s.replace('Z', '+00:00'))
print(int((f(e[-1]['t']) - f(e[0]['t'])).total_seconds()))
PY
)" || fail "could not compute the span - is every t a parseable timestamp?"
[ "$span" -ge 10 ] || fail "the whole timeline spans ${span}s - too short to be a provisioning run"
ok "$n events across $lanes lanes, spanning ${span}s"

# ---------------------------- 6. three events are re-derived from independent sources
if ! python3 - <<'PY'; then
import datetime as dt
import json
import re
import subprocess
import sys

doc = json.load(open('/tmp/s21.json'))


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout


def secs(s):
    s = s.strip().replace('Z', '+00:00')
    m = re.match(r'^(.*\.\d{6})\d*(\+00:00)$', s)
    if m:
        s = m.group(1) + m.group(2)
    return dt.datetime.fromisoformat(s).replace(microsecond=0)


problems = []

deploys = [e for e in doc['events'] if e['kind'] == 'deployment.applied']
if not deploys:
    problems.append('no deployment.applied event')
else:
    ns, _, name = deploys[0]['subject'].partition('/')
    real = sh('kubectl get deploy %s -n %s -o jsonpath={.metadata.creationTimestamp}'
              % (name, ns)).strip()
    if not real:
        problems.append('kubectl did not answer for %s' % deploys[0]['subject'])
    elif secs(real) != secs(deploys[0]['t']):
        problems.append('deployment.applied says %s, kubectl says %s'
                        % (deploys[0]['t'], real))

starts = [e for e in doc['events'] if e['kind'] == 'container.started']
if not starts:
    problems.append('no container.started event')
else:
    real = sh("docker inspect -f '{{.State.StartedAt}}' %s" % starts[0]['subject']).strip()
    if not real or real.startswith('0001'):
        problems.append('docker inspect does not know container %s' % starts[0]['subject'])
    elif secs(real) != secs(starts[0]['t']):
        problems.append('container.started says %s, docker says %s' % (starts[0]['t'], real))

calls = [e for e in doc['events'] if e['kind'] == 'runner.call']
if not calls:
    problems.append('no runner.call event')
else:
    log = sh('docker logs --timestamps jit-runner 2>&1')
    stamps = [secs(l.split()[0]) for l in log.splitlines() if 'POST /v1/runs' in l]
    if not stamps:
        problems.append("the runner's own log has no POST /v1/runs line")
    elif secs(calls[0]['t']) not in stamps:
        problems.append('runner.call says %s, the runner logged %s'
                        % (calls[0]['t'], [s.isoformat() for s in stamps]))

if problems:
    print('FAIL: ' + '; '.join(problems))
    sys.exit(1)
PY
  fail "the timeline disagrees with kubectl, docker or the runner's log (see the FAIL line above)"
fi
ok "three events re-derive from kubectl, docker inspect and the runner's own log"

# ------------------------------------- 7. the /state poll stays cheap and unchanged
state="$(make -s state 2>/dev/null)" || fail "make state exited non-zero"
jq -e 'has("events") | not' <<<"$state" >/dev/null \
  || fail "make state now carries the events - the two-second poll must stay cheap"
jq -e 'has("timeline") | not' <<<"$state" >/dev/null \
  || fail "make state now carries the timeline - it is a target of its own, not a key in the poll"
ok "make state's document carries no timeline"

echo "PASS"
