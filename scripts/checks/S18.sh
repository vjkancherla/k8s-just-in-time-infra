#!/usr/bin/env bash
# S18 - the Makefile surface the console drives.
#
# Written before the implementation, and frozen. If this looks wrong, stop and ask;
# do not adjust it to match the code.
#
# Corrected 2026-09-12, on the human's approval, for two mechanics that no implementation
# could ever satisfy - the assertions below are unchanged. (1) `make -pRrq :` exits 2, and
# 141 when `grep -q` matches and closes the pipe, while this script sets `pipefail`, so line
# 19's pipeline was non-zero even for a target the database lists. (2) A herestring is
# applied after a heredoc, so line 40 handed `python3 -` the read model as its *script*
# instead of its stdin. Both are visible in docs/evidence/s18-checkpoint-probe.log, which
# records this file's failure and the same file's PASS with only those two mechanics fixed.
#
# Precondition: the demo stack is up (make demo-up). This checkpoint asserts against a
# live cluster; it fails rather than skips if there is nothing there.
set -euo pipefail

cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $1"; exit 1; }
ok()   { echo "  ok: $1"; }

TARGETS=(demo-up demo-soft demo-restore ns-delete test-up jit-up verify jit-verify jit-down state targets)

# ---------------------------------------------------------------- 1. allowlist exists
target_defined() { { make -pRrq : 2>/dev/null || true; } | grep -Eq "^$1:( |$)"; }

for t in "${TARGETS[@]}"; do
  target_defined "$t" || fail "no make target '$t'"
done
ok "all ${#TARGETS[@]} targets defined"

# ------------------------------------------------- 2. make targets is the same allowlist
listed="$(make -s targets 2>/dev/null | sed '/^[[:space:]]*$/d' | sort)" \
  || fail "make targets did not run"
expected="$(printf '%s\n' "${TARGETS[@]}" | sort)"
[ "$listed" = "$expected" ] || fail "make targets disagrees with the allowlist
  listed:
$listed
  expected:
$expected"
ok "make targets prints the allowlist and nothing else"

# ---------------------------------------------------------- 3. state is a single object
state="$(make -s state 2>/dev/null)" || fail "make state exited non-zero"

python3 - "$state" <<'PY' || fail "make state is not the documented shape"
import json,sys
d = json.loads(sys.argv[1])
for k in ("up","generatedAt","namespaces","containers","stateObjects"):
    assert k in d, f"missing key {k}"
assert isinstance(d["namespaces"], list)
assert isinstance(d["containers"], list)
assert isinstance(d["stateObjects"], list)
for ns in d["namespaces"]:
    for k in ("name","block","claims"):
        assert k in ns, f"namespace missing {k}"
    for c in ns["claims"]:
        for k in ("module","phase","address","referencedBy","expiresAt"):
            assert k in c, f"claim missing {k}"
        assert isinstance(c["referencedBy"], list)
for c in d["containers"]:
    for k in ("name","address","running"):
        assert k in c, f"container missing {k}"
PY
ok "make state emits the documented JSON"

[ "$(jq -r .up <<<"$state")" = "true" ] \
  || fail "make state says up=false - run 'make demo-up' before this checkpoint"

# ------------------------------------------------- 4. state agrees with the real sources
claims_json=$(jq '[.namespaces[].claims[]] | length' <<<"$state")
claims_real=$(kubectl get infraclaims -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$claims_json" = "$claims_real" ] \
  || fail "make state reports $claims_json claims, kubectl reports $claims_real"
ok "claim count matches kubectl ($claims_real)"

for row in $(jq -r '.namespaces[].claims[] | "\(.module)|\(.phase)"' <<<"$state"); do
  mod="${row%%|*}"; phase="${row##*|}"
  real=$(kubectl get infraclaims -A -o jsonpath="{.items[?(@.spec.module=='$mod')].status.phase}" 2>/dev/null | awk '{print $1}')
  [ -n "$real" ] || fail "claim for module '$mod' is in make state but not in the cluster"
  [ "$phase" = "$real" ] || fail "make state says $mod is $phase, the cluster says $real"
done
ok "every reported phase matches the cluster"

running_json=$(jq '[.containers[] | select(.running)] | length' <<<"$state")
running_real=$(docker ps --format '{{.Names}}' | grep -c -- '-voting-' || true)
[ "$running_json" = "$running_real" ] \
  || fail "make state reports $running_json running containers, docker reports $running_real"
ok "container count matches docker ($running_real)"

# -------------------------------------------------------- 5. state survives no cluster
nostate="$(KUBECONFIG=/nonexistent/kubeconfig make -s state 2>/dev/null)" \
  || fail "make state exited non-zero with no cluster - the console polls it before one exists"
jq -e '.up == false' <<<"$nostate" >/dev/null \
  || fail "make state with no cluster should report up=false and empty lists"
ok "make state degrades to up=false instead of erroring"

# --------------------------------------------------------------- 6. ns-delete is fenced
if make -s ns-delete >/dev/null 2>&1; then
  fail "ns-delete ran with no NS"
fi
if make -s ns-delete NS=default >/dev/null 2>&1; then
  fail "ns-delete accepted NS=default - it must refuse anything outside voting-a voting-b"
fi
if make -s ns-delete NS=kube-system >/dev/null 2>&1; then
  fail "ns-delete accepted NS=kube-system"
fi
ok "ns-delete refuses a missing or unlisted namespace"

# ------------------------------------------------------ 7. failure exits non-zero
if make -s verify NS=does-not-exist >/dev/null 2>&1; then
  fail "verify against a missing namespace exited 0 - a target that cannot fail is not a gate"
fi
ok "a failing target exits non-zero"

# ----------------------------------------------- 8. the soft path is visible in state
make -s demo-soft >/dev/null 2>&1 || fail "make demo-soft exited non-zero"
sleep 35   # one resync tick plus slack

soft="$(make -s state)"
jq -e '[.namespaces[].claims[] | select(.phase == "Orphaned")] | length >= 1' <<<"$soft" >/dev/null \
  || fail "no claim went Orphaned after demo-soft"
jq -e '[.namespaces[].claims[] | select(.phase == "Orphaned" and .expiresAt != null)] | length >= 1' <<<"$soft" >/dev/null \
  || fail "an Orphaned claim has no expiresAt - the console has nothing to count down"
jq -e '[.namespaces[].claims[] | select(.module == "redis" and .phase == "Ready")] | length == 1' <<<"$soft" >/dev/null \
  || fail "redis did not stay Ready - worker still references it"
jq -e '[.containers[] | select(.running)] | length == 3' <<<"$soft" >/dev/null \
  || fail "a container stopped during the retention window - nothing should be destroyed yet"
ok "demo-soft orphans with an expiry, keeps redis Ready, destroys nothing"

make -s demo-restore >/dev/null 2>&1 || fail "make demo-restore exited non-zero"
sleep 35

back="$(make -s state)"
jq -e '[.namespaces[].claims[] | select(.phase != "Ready")] | length == 0' <<<"$back" >/dev/null \
  || fail "a claim did not return to Ready after demo-restore"
jq -e '[.namespaces[].claims[] | select(.expiresAt != null)] | length == 0' <<<"$back" >/dev/null \
  || fail "expiresAt was not cleared on resurrection"
ok "demo-restore returns every claim to Ready with the expiry cleared"

# ---------------------------------------------------------------- 9. evidence is written
for t in demo-soft demo-restore; do
  [ -s "docs/evidence/$t.log" ] || fail "no docs/evidence/$t.log after running $t"
done
ok "each run left its log in docs/evidence/"

echo "PASS"
