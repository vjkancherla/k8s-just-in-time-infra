#!/usr/bin/env bash
# S19 - the console page over `make state`.
#
# Written before this step had a checkpoint, from the Goal in docs/build-plan.md S19, and
# frozen from here on: if this looks wrong, stop and ask - do not adjust it to match the
# code. The page was built outside the plan, so this is a retro-checkpoint and a FAIL here
# is a finding about the page, not a reason to soften the assertion.
#
# Precondition: the demo stack is up (make demo-up). The last assertions compare the page
# against a live read model, and they fail rather than skip if nothing is there.
#
# Mechanics corrected 2026-09-15, while this step was still being implemented and before this
# file was first committed: three extraction pipelines were unguarded, so when `grep` matched
# nothing it exited 1 and `pipefail` aborted the whole file - silently, without printing a
# FAIL. Each is now `{ grep ... || true; } | ...`. No assertion changed. Assertion 3 is now
# vacuous by design, because the page names no make target at all once the snapshot mode was
# cut; its teeth are shown in docs/evidence/s19-retro-check.log by running this same file
# against a copy of the page that names `make console` again, and getting the FAIL.
set -euo pipefail

cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $1"; exit 1; }
ok()   { echo "  ok: $1"; }

PAGE=console/index.html
[ -s "$PAGE" ] || fail "no $PAGE"

# ------------------------------------------- 1. one file, no build step, no dependencies
if grep -qE '<script[^>]+src=|<link[^>]+href="http' "$PAGE"; then
  fail "the page loads a script or a stylesheet from outside itself"
fi
ok "one file, no external script and no external stylesheet"

# --------------------------------- 2. every button is one allowlisted make target
allowlist="$(make -s targets 2>/dev/null)" || fail "make targets did not run"
[ -n "$allowlist" ] || fail "make targets printed nothing"

{ grep -oE "cmd:'make [a-z][a-z0-9-]*" "$PAGE" || true; } | sed 's/.*make //' | sort -u > /tmp/s19-buttons.txt
[ -s /tmp/s19-buttons.txt ] || fail "no cmd: entries in the page - its buttons are unreadable"

while read -r t; do
  [ -n "$t" ] || continue
  grep -qx "$t" <<<"$allowlist" \
    || fail "a button runs 'make $t', which make targets does not list"
done < /tmp/s19-buttons.txt
ok "all $(wc -l < /tmp/s19-buttons.txt | tr -d ' ') buttons are targets make targets lists"

if grep -qE "cmd:'[^']*(kubectl|docker|;|&&|\|\|)" "$PAGE"; then
  fail "a button runs something other than one plain make command"
fi
ok "every button is one plain make command"

# ------------- 3. any target the page tells the user to run is a target that exists
# A page that says "run `make console`" when there is no console target is the same drift
# as a button the allowlist cannot run, one line further out.
target_defined() { { make -pRrq : 2>/dev/null || true; } | grep -Eq "^$1:( |$)"; }

{ grep -oE '`make [a-z][a-z0-9-]*`' "$PAGE" || true; } | sed 's/`//g; s/make //' | sort -u > /tmp/s19-named.txt
while read -r t; do
  [ -n "$t" ] || continue
  target_defined "$t" \
    || fail "the page tells the user to run 'make $t', which the Makefile does not define"
done < /tmp/s19-named.txt
ok "every target the page names is defined ($(tr '\n' ' ' < /tmp/s19-named.txt))"

# --------------------------- 4. the page calls only the console's own endpoints
{ grep -oE "fetch\('/[a-z]+" "$PAGE" || true; } | sed "s/fetch('//" | sort -u > /tmp/s19-endpoints.txt
[ -s /tmp/s19-endpoints.txt ] || fail "the page calls no endpoint at all"

while read -r e; do
  [ -n "$e" ] || continue
  case "$e" in
    /state|/claim|/log|/run) ;;
    *) fail "the page calls $e, which is not one of /state /claim /log /run" ;;
  esac
done < /tmp/s19-endpoints.txt
ok "the page calls only the console's endpoints ($(tr '\n' ' ' < /tmp/s19-endpoints.txt))"

# --------------------------------- 5. the page keeps the last good state on failure
python3 - "$PAGE" <<'PY' > /tmp/s19-poll.txt || fail "could not read the page's poll"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'async function poll\(\)\{(.*?)\n\}', src, re.S)
print(m.group(1) if m else '')
PY
[ -s /tmp/s19-poll.txt ] || fail "the page has no poll() - where does its state come from?"
if ! grep -q 'catch' /tmp/s19-poll.txt; then
  fail "poll() has no catch - one failed fetch would empty the page"
fi
if grep -qE 'S\.data *= *null' /tmp/s19-poll.txt; then
  fail "poll() clears S.data when /state fails - the page must keep the last good state"
fi
ok "poll() keeps the last good state when /state fails"

# ----------------------------- 6. every field the page reads exists in the read model
state="$(make -s state 2>/dev/null)" || fail "make state exited non-zero"
jq -e '.up == true' <<<"$state" >/dev/null \
  || fail "make state says up=false - run 'make demo-up' before this checkpoint"
jq -e '.namespaces | length >= 1' <<<"$state" >/dev/null \
  || fail "make state reports no namespaces - run 'make demo-up' before this checkpoint"

python3 - "$PAGE" <<'PY' > /tmp/s19-keys.txt
import re, sys
src = open(sys.argv[1]).read()
for k in sorted(set(re.findall(r'S\.data\.([A-Za-z]+)', src))):
    print('data', k)
for k in sorted(set(re.findall(r'(?<![A-Za-z0-9_])ns\.([a-z]+)', src))):
    print('ns', k)
PY
[ -s /tmp/s19-keys.txt ] || fail "the page reads nothing out of the read model"
grep -q 'ingressPorts' /tmp/s19-keys.txt \
  || fail "the page no longer reads reading ingressPorts - this assertion has gone vacuous, which is itself a finding"

while read -r kind k; do
  [ -n "$k" ] || continue
  case "$kind" in
    data) jq -e --arg k "$k" 'has($k)' <<<"$state" >/dev/null \
            || fail "the page reads S.data.$k, which make state does not emit" ;;
    ns)   jq -e --arg k "$k" '[.namespaces[] | has($k)] | all' <<<"$state" >/dev/null \
            || fail "the page reads ns.$k, which make state does not emit for a namespace" ;;
  esac
done < /tmp/s19-keys.txt
ok "every field the page reads exists in make state"

echo "PASS"
