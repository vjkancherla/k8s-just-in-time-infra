#!/usr/bin/env bash
# S20 - the proxy: the allowlist, one run at a time, and nothing else.
#
# Written before this step had a checkpoint, from the Goal in docs/build-plan.md S20, and
# frozen from here on: if this looks wrong, stop and ask - do not adjust it to match the
# code. serve.py was built outside the plan, so this is a retro-checkpoint and a FAIL here
# is a finding about the proxy.
#
# Precondition: the demo stack is up (make demo-up) - /state is read through the proxy once,
# which is what proves the proxy and the read model are wired to each other.
set -euo pipefail

cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $1"; exit 1; }
ok()   { echo "  ok: $1"; }

SERVER=console/serve.py
TESTS=console/test_serve.py
[ -s "$SERVER" ] || fail "no $SERVER"
[ -s "$TESTS" ]  || fail "no $TESTS"

# ---------------------------------------------------- 1. the diagnostic suite passes
if ! python3 "$TESTS" > /tmp/s20-tests.log 2>&1; then
  sed -n '1,60p' /tmp/s20-tests.log
  fail "console/test_serve.py did not pass"
fi
ok "console/test_serve.py passes ($(grep -oE 'Ran [0-9]+ tests' /tmp/s20-tests.log | head -1))"

# --------------------------- 2. every ALLOWED value is an allowlisted make command
allowlist="$(make -s targets 2>/dev/null)" || fail "make targets did not run"

if ! python3 - "$SERVER" <<'PY' > /tmp/s20-allowed.txt; then
import importlib.util, sys
spec = importlib.util.spec_from_file_location("serve_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for name, cmd in mod.ALLOWED.items():
    print("%s\t%s" % (name, " ".join(cmd)))
print("#STATE\t%s" % " ".join(mod.STATE))
print("#CLAIM\t%s" % " ".join(mod.CLAIM))
PY
  fail "could not read ALLOWED / STATE / CLAIM out of $SERVER"
fi
[ -s /tmp/s20-allowed.txt ] || fail "ALLOWED is empty - the proxy can run nothing"

while IFS=$'\t' read -r name cmd; do
  case "$name" in \#*) continue ;; esac
  [ -n "$name" ] || continue
  [ "${cmd%% *}" = "make" ] || fail "ALLOWED['$name'] does not start with make: $cmd"
  rest="${cmd#make }"
  target="${rest%% *}"
  grep -qx "$target" <<<"$allowlist" \
    || fail "ALLOWED['$name'] runs 'make $target', which make targets does not list"
  case "$cmd" in
    *';'*|*'|'*|*'&'*|*'$('*|*'>'*|*'<'*)
      fail "ALLOWED['$name'] carries shell metacharacters: $cmd" ;;
  esac
done < /tmp/s20-allowed.txt
ok "$(grep -vc '^#' /tmp/s20-allowed.txt) ALLOWED entries are allowlisted make targets"

state_cmd="$(awk -F'\t' '$1 == "#STATE" { print $2 }' /tmp/s20-allowed.txt)"
[ "$state_cmd" = "make -s state" ] \
  || fail "the proxy's /state is not 'make -s state' (got: $state_cmd)"
claim_cmd="$(awk -F'\t' '$1 == "#CLAIM" { print $2 }' /tmp/s20-allowed.txt)"
[ "$claim_cmd" = "make -s claim" ] \
  || fail "the proxy's /claim is not 'make -s claim' (got: $claim_cmd)"
grep -qx claim <<<"$allowlist" || fail "'claim' is not in make targets - /claim calls a target the allowlist does not list"
ok "/state is make state and /claim is make claim, both allowlisted"

# ---------------- 3. the fence is ALLOWED, not the target list, and the repo is not served
if ! python3 - "$SERVER" <<'PY'; then
import importlib.util, json, sys, threading, urllib.error, urllib.request

spec = importlib.util.spec_from_file_location("serve_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
srv = mod.build_server(0)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d" % srv.server_address[1]


def call(path, method="GET"):
    req = urllib.request.Request(base + path, method=method,
                                 data=b"" if method == "POST" else None)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


problems = []
# /state and /targets are in make targets but they are reads: POST must refuse them.
for path in ("/run/state", "/run/targets", "/run/not-a-target"):
    code, _ = call(path, "POST")
    if code != 404:
        problems.append("%s answered %s, not 404" % (path, code))
# Nothing but the page and the console's own endpoints is served.
for path in ("/deploy/.env", "/.git/config", "/Makefile", "/console/serve.py"):
    code, _ = call(path)
    if code != 404:
        problems.append("GET %s answered %s, not 404" % (path, code))

code, body = call("/state")
if code != 200:
    problems.append("/state answered %s" % code)
else:
    try:
        doc = json.loads(body)
    except ValueError:
        problems.append("/state did not answer JSON")
    else:
        if "up" not in doc:
            problems.append("/state's object has no 'up'")
        elif doc["up"] is not True:
            problems.append("/state says up=%r - run 'make demo-up' first" % doc["up"])

srv.shutdown()
if problems:
    print("FAIL: " + "; ".join(problems))
    sys.exit(1)
PY
  fail "the proxy's fence or its 404 is broken (see the FAIL line above)"
fi
ok "POST refuses reads and unknown names, the repo is not served, /state answers"

# ------------------------------ 4. the design's two behaviours have tests behind them
grep -q 'def test_one_run_at_a_time' "$TESTS" \
  || fail "no test for one run at a time - the design requires 409 on a second run"
grep -q 'def test_the_log_offset_returns_only_what_is_new' "$TESTS" \
  || fail "no test for the log offset - the page tails a run through it"
ok "the suite covers the run lock and the log offset"

# ------------------------------------------------- 5. nothing goes through a shell
if grep -qE 'shell *= *True|os\.system\(|subprocess\.(call|check_output|Popen|run)\([^[]*"' "$SERVER"; then
  fail "serve.py builds a command string or shells out - every command must be a list"
fi
ok "no shell: every command is a list"

echo "PASS"
