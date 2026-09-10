#!/usr/bin/env bash
set -euo pipefail

# S17 checkpoint - two namespaces, the JIT acceptance suite, Makefile targets.
#
# From docs/build-plan.md S17:
#   "**Checkpoint** `scripts/checks/S17.sh`: `make jit-verify` passes J1-J11, and
#    `make verify` still reports 17 PASS in `voting-a`."
#
# Turned into assertions, with these documented assumptions:
#   - the root Makefile exposes jit-up, jit-verify, jit-down and check
#     (build-plan S17's target table);
#   - `.workflow/verify-jit.md` uses the same line shape as verify.sh's
#     `.workflow/verify.md` - `<id> <PASS|FAIL> <message>` - since the plan says
#     "same shape as verify.sh" and names J1-J11;
#   - the suite may write that file at the repo root or under app/. Both are
#     accepted; a stale artifact is deleted first so it cannot pass the gate;
#   - `make verify` targets the demo namespace `voting-a`. The namespace is
#     offered as both NS and NAMESPACE so either spelling is honoured.
#
# FROZEN (build-plan.md S-1). If this is wrong, raise a design question - do not
# adjust it to match the code.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

DEMO_NS="voting-a"
EXPECTED_VERIFY="===== 17 PASS, 0 FAIL ====="
JIT_LOG=""
VERIFY_LOG=""

cleanup() {
  rm -f "$JIT_LOG" "$VERIFY_LOG" 2>/dev/null || true
}
trap cleanup EXIT
JIT_LOG="$(mktemp)"
VERIFY_LOG="$(mktemp)"

artifact() {  # echo the first existing path among the accepted ones
  local p
  for p in "$@"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  echo ""
}

# ── Preconditions: the root Makefile and its documented targets ──────────────

[[ -f "Makefile" ]] || fail "no root Makefile - S17 adds jit-up, jit-verify, jit-down and check"
[[ -f "scripts/verify-jit.sh" ]] || fail "scripts/verify-jit.sh does not exist"

for t in jit-up jit-verify jit-down check; do
  grep -qE "^${t}:" Makefile || fail "the root Makefile has no '${t}' target"
  echo "PASS: root Makefile declares ${t}"
done

# `make check STEP=NN` must actually route to a checkpoint script. Dry run, so
# no checkpoint is re-executed from inside this one.
if ! make -n check STEP=15 > "$JIT_LOG" 2>&1; then
  cat "$JIT_LOG"
  fail "make check STEP=15 failed in dry-run mode"
fi
grep -q 'scripts/checks/S15.sh' "$JIT_LOG" \
  || fail "make check STEP=15 does not run scripts/checks/S15.sh"
echo "PASS: make check STEP=NN routes to scripts/checks/SNN.sh"

docker inspect jit-runner >/dev/null 2>&1 || fail "jit-runner container not running"

# ── make jit-verify: J1-J11 (build-plan's four that matter: J4, J5, J8, J9) ───

rm -f ".workflow/verify-jit.md" "app/.workflow/verify-jit.md"
if make jit-verify > "$JIT_LOG" 2>&1; then
  JIT_RC=0
else
  JIT_RC=$?
fi
tail -5 "$JIT_LOG" | sed 's/^/  /'
[[ "$JIT_RC" -eq 0 ]] || { grep -E '^J[0-9]+[[:space:]]+FAIL' "$JIT_LOG" | head -20 || true; \
  fail "make jit-verify exited $JIT_RC (verify-jit.sh must use set -euo pipefail and exit non-zero)"; }

JIT_MD="$(artifact ".workflow/verify-jit.md" "app/.workflow/verify-jit.md")"
[[ -n "$JIT_MD" ]] || fail "make jit-verify did not write .workflow/verify-jit.md"
echo "PASS: make jit-verify exited 0 and wrote $JIT_MD"

for n in $(seq 1 11); do
  if ! grep -qE "^J${n}[[:space:]]+PASS" "$JIT_MD"; then
    echo "--- J-check lines in $JIT_MD ---"
    grep -E '^J[0-9]+' "$JIT_MD" | head -20 || true
    fail "J${n} did not report PASS"
  fi
done
grep -qE '^J[0-9]+[[:space:]]+FAIL' "$JIT_MD" && fail "a J-check reported FAIL in $JIT_MD"
echo "PASS: J1-J11 all PASS in $JIT_MD"

# ── make verify still reports 17 PASS, now in voting-a ───────────────────────

kubectl get ns "$DEMO_NS" >/dev/null 2>&1 || fail "namespace $DEMO_NS does not exist"
for comp in vote worker result; do
  name="$(kubectl get deploy -n "$DEMO_NS" -l "app.kubernetes.io/component=${comp}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$name" ]] || fail "no Deployment labelled app.kubernetes.io/component=$comp in $DEMO_NS"
  kubectl rollout status "deployment/$name" -n "$DEMO_NS" --timeout=300s >/dev/null 2>&1 \
    || fail "deployment $name (component=$comp) is not Ready in $DEMO_NS"
done
for c in "${DEMO_NS}-redis-redis" "${DEMO_NS}-postgres-postgres" "${DEMO_NS}-pgadmin-pgadmin"; do
  docker container inspect "$c" >/dev/null 2>&1 || fail "container $c is not running"
done
[[ -z "$(kubectl get statefulset -n "$DEMO_NS" -o name)" ]] || fail "a StatefulSet exists in $DEMO_NS"
[[ -z "$(kubectl get pvc -n "$DEMO_NS" -o name)" ]] || fail "a PersistentVolumeClaim exists in $DEMO_NS"
echo "PASS: $DEMO_NS runs the migrated app on three containers, no StatefulSet, no PVC"

rm -f ".workflow/verify.md" "app/.workflow/verify.md"
if NS="$DEMO_NS" NAMESPACE="$DEMO_NS" make verify > "$VERIFY_LOG" 2>&1; then
  VERIFY_RC=0
else
  VERIFY_RC=$?
fi
tail -5 "$VERIFY_LOG" | sed 's/^/  /'

VERIFY_MD="$(artifact ".workflow/verify.md" "app/.workflow/verify.md")"
[[ -n "$VERIFY_MD" ]] || fail "make verify did not write .workflow/verify.md"
SUMMARY="$(grep -E '^===== [0-9]+ PASS, [0-9]+ FAIL =====$' "$VERIFY_MD" | tail -1 || true)"
if [[ "$SUMMARY" != "$EXPECTED_VERIFY" ]]; then
  echo "--- failing checks in $VERIFY_MD ---"
  grep -E '^R[0-9]+[[:space:]]+FAIL' "$VERIFY_MD" | head -20 || true
  fail "expected '$EXPECTED_VERIFY' in $VERIFY_MD, got '${SUMMARY:-no summary line}' (make verify exit $VERIFY_RC)"
fi
echo "PASS: $EXPECTED_VERIFY in $DEMO_NS"

echo "PASS: S17 - two namespaces, J1-J11 and the R-checks both green"
