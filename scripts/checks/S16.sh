#!/usr/bin/env bash
set -euo pipefail

# S16 checkpoint - `make verify` is 17 PASS again, against out-of-cluster infra.
#
# From docs/build-plan.md S16:
#   "**Checkpoint** `scripts/checks/S16.sh`: run `make verify`, parse
#    `.workflow/verify.md`, assert `17 PASS, 0 FAIL`."
#
# Two notes on how that is turned into assertions here:
#   - `make verify` is `app/Makefile`'s target, run from `app/` - the root
#     Makefile's targets arrive in S17. `verify.sh`'s own docs say to parse
#     `.workflow/verify.md` and never trust its exit code, which is 0 even when
#     checks fail, so the exit code is captured but not asserted on.
#   - S16 must not regress the migration, so no StatefulSet and no PVC may be
#     left in the namespace.
#
# FROZEN (build-plan.md S-1). If this is wrong, raise a design question - do not
# adjust it to match the code.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

fail() { echo "FAIL: $1"; exit 1; }

NS="${NS:-default}"
VERIFY_MD="app/.workflow/verify.md"
EXPECTED="===== 17 PASS, 0 FAIL ====="
LOG=""

cleanup() {
  rm -f "$LOG" 2>/dev/null || true
}
trap cleanup EXIT
LOG="$(mktemp)"

# ── Preconditions ────────────────────────────────────────────────────────────

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace $NS does not exist"

for comp in vote worker result; do
  name="$(kubectl get deploy -n "$NS" -l "app.kubernetes.io/component=${comp}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$name" ]] || fail "no Deployment labelled app.kubernetes.io/component=$comp in $NS - deploy the migrated app first"
  kubectl rollout status "deployment/$name" -n "$NS" --timeout=300s >/dev/null 2>&1 \
    || fail "deployment $name (component=$comp) is not Ready"
done

# The stateful tiers must exist as containers, or the reworked R2/R8/R9/R16/R17
# cannot pass and the failure would be misread as a verify.sh defect.
for c in "${NS}-redis-redis" "${NS}-postgres-postgres"; do
  docker container inspect "$c" >/dev/null 2>&1 || fail "container $c is not running - the JIT infra is not up"
done

# ── Run make verify (in app/, the Makefile that exists before S17) ───────────

rm -f "$VERIFY_MD"
if ( cd app && make verify ) > "$LOG" 2>&1; then
  VERIFY_RC=0
else
  VERIFY_RC=$?
fi
tail -5 "$LOG" | sed 's/^/  /'

[[ -f "$VERIFY_MD" ]] || fail "make verify did not write $VERIFY_MD"
echo "PASS: make verify ran and wrote $VERIFY_MD (exit $VERIFY_RC - not asserted on)"

# ── Assert the summary line ──────────────────────────────────────────────────

SUMMARY="$(grep -E '^===== [0-9]+ PASS, [0-9]+ FAIL =====$' "$VERIFY_MD" | tail -1 || true)"
if [[ "$SUMMARY" != "$EXPECTED" ]]; then
  echo "--- failing checks in $VERIFY_MD ---"
  grep -E '^R[0-9]+[[:space:]]+FAIL' "$VERIFY_MD" | head -20 || true
  fail "expected '$EXPECTED', got '${SUMMARY:-no summary line}'"
fi
echo "PASS: $EXPECTED"

# ── The migration must not have been undone ──────────────────────────────────

[[ -z "$(kubectl get statefulset -n "$NS" -o name)" ]] || fail "a StatefulSet exists in $NS - the migration was undone"
[[ -z "$(kubectl get pvc -n "$NS" -o name)" ]] || fail "a PersistentVolumeClaim exists in $NS - the migration was undone"
echo "PASS: no StatefulSet and no PVC in $NS"

echo "PASS: S16 - make verify reports 17 PASS, 0 FAIL against out-of-cluster infra"
