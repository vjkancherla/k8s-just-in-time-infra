#!/usr/bin/env bash
# S23 - Spike: container-replace timings, vote loss, and the call_runner
# blocking verdict. Decides whether redis `maxmemory` stays in the mutable
# surface (design U1). PROTOCOL: with the demo stack up, replace the redis
# container (re-POST its run with a changed maxmemory) and the postgres
# container (re-POST with a changed -c setting), timing each, counting
# `LLEN votes` lost across the replace, and asserting the worker re-drains;
# record whether call_runner runs synchronously inside the kopf handler.
# Everything measured goes into docs/evidence/s23-spike.log.
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }
LOG=docs/evidence/s23-spike.log

[ -f "$LOG" ] || fail "docs/evidence/s23-spike.log missing - run the spike protocol first"

# measured, never typed: numbers with units on the line
grep -qEi 'redis replace[^0-9]*[0-9]+s' "$LOG" \
  || fail "no measured redis replace time in s23-spike.log"
grep -qEi 'postgres replace[^0-9]*[0-9]+s' "$LOG" \
  || fail "no measured postgres replace time in s23-spike.log"
grep -qEi 'votes lost[^0-9]*[0-9]+' "$LOG" \
  || fail "no measured vote-loss count in s23-spike.log"
grep -qi 'reconnect' "$LOG" \
  || fail "no vote/worker reconnect observation in s23-spike.log"
grep -qEi 'call_runner[^.]*block' "$LOG" \
  || fail "no call_runner blocking verdict in s23-spike.log"

# the decision, spelled and matching one of the two allowed verdicts
verdict="$(grep -Ei '^VERDICT: maxmemory' "$LOG" | tail -1)" \
  || fail "no 'VERDICT: maxmemory ...' line in s23-spike.log"
case "$verdict" in
  'VERDICT: maxmemory mutable'|'VERDICT: maxmemory refused')
    echo "PASS S23: spike measured (both replaces, vote loss, reconnect), verdict: $verdict" ;;
  *)
    fail "the final verdict does not read exactly 'VERDICT: maxmemory mutable' or 'VERDICT: maxmemory refused': $verdict";;
esac
