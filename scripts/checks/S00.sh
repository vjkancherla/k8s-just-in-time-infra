#!/usr/bin/env bash
#
# Checkpoint S0 - Baseline.
#
# The unmodified voting app runs on a k3d cluster with the fixed subnet the rest of
# this work needs. Nothing is JIT yet.
#
# Run from the work root (k8s-just-in-time-infra/):
#     ./scripts/checks/S00.sh
# Later, via the Makefile idiom:
#     make check STEP=00
#
# Exits 0 and prints PASS only if ALL of:
#   1. k3d network `k3d-voting-app` has subnet 172.19.0.0/16
#   2. all 5 workloads (vote, worker, result, redis, postgres) are Ready
#   3. app/.workflow/verify.md reports 17 PASS, 0 FAIL
#
# STALE FROM S15 - assertions 2 and 3 describe a state that no longer exists.
# This gate is NOT edited to match the code (build-plan S-1); re-opening it was
# considered and rejected in docs/reviews/S15-findings.md item 9.
#
#   Assertion 2: S15 removed the redis Deployment and the postgres StatefulSet from
#     app/kustomize, so a migrated deployment has no `voting-app-redis` or
#     `voting-app-postgres` to find.
#   Assertion 3: S16 reworks the R-checks that the migration invalidated, so
#     verify.md is not 17 PASS again until S16 lands.
#
# The failure is LATENT, which makes it easy to misread: this script inspects
# namespace `default` and parses whatever verify.md already contains. While the
# pre-S15 app is still deployed there, it passes - verified 2026-10-09, exit 0,
# against the old Deployment and a stale verify.md. It starts failing the moment
# the migrated app is deployed and verify.sh is reworked (S16), and the failure
# message names the missing workload, so the diagnosis is immediate.
#
# It is a historical baseline for the pre-JIT app, and a reminder that this gate
# reads verify.md rather than running verify.sh.
set -euo pipefail

# Resolve the work root from this script's path:
#   <workroot>/scripts/checks/S00.sh  ->  up two levels.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# All the app lives under app/ - work from there so paths match verify.sh.
cd "$ROOT/app"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Fixed subnet present on the k3d network.
subnet=$(docker network inspect k3d-voting-app 2>/dev/null \
  | jq -r '.[0].IPAM.Config[].Subnet' 2>/dev/null | tr '\n' ' ' || true)
case "$subnet" in
  *"172.19.0.0/16"*) : ;;
  *) fail "k3d-voting-app subnet is '$subnet', expected 172.19.0.0/16" ;;
esac

# 2. All 5 workloads have every replica ready.
for w in voting-app-vote voting-app-worker voting-app-result voting-app-redis; do
  ready=$(kubectl get deploy "$w" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  desir=$(kubectl get deploy "$w" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  [[ "$ready" == "$desir" && "$ready" =~ ^[1-9][0-9]*$ ]] \
    || fail "$w not ready (ready='$ready' desired='$desir')"
done
ready=$(kubectl get sts voting-app-postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
desir=$(kubectl get sts voting-app-postgres -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
[[ "$ready" == "$desir" && "$ready" =~ ^[1-9][0-9]*$ ]] \
  || fail "voting-app-postgres not ready (ready='$ready' desired='$desir')"

# 3. verify.md reports 17 PASS, 0 FAIL. Parse the file - never trust verify.sh's exit
#    code, which is 0 even when checks fail.
[[ -f .workflow/verify.md ]] || fail ".workflow/verify.md not found"
pass=$(grep -cE '^R[0-9]+[[:space:]]+PASS' .workflow/verify.md || true)
bad=$(grep -cE '^R[0-9]+[[:space:]]+FAIL' .workflow/verify.md || true)
[[ "$pass" == "17" ]] || fail "expected 17 PASS in verify.md, got $pass"
[[ "$bad" == "0" ]] || fail "expected 0 FAIL in verify.md, got $bad"

echo "PASS: subnet 172.19.0.0/16 present, 5/5 workloads Ready, verify.md = 17 PASS, 0 FAIL"
