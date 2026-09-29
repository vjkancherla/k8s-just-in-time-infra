#!/usr/bin/env bash
# S25 - CRD: the pruned-proof schema gains the update fields.
# appliedParams, attemptedParamsHash, declaredBy, the DECLARED printer column
# and the seven new conditions must be schema-listed, and a patched field must
# survive a round-trip through the API server.
# Precondition: the cluster and CRD are up (make jit-up).
set -euo pipefail
fail() { echo "FAIL: $1"; exit 1; }

# Bodied kubectl: a dead API server cannot hang the checkpoint or its cleanup trap.
kk() { kubectl --request-timeout=5s "$@"; }
CRD=deploy/crd/infraclaim.yaml

kk get crd infraclaims.jit.io >/dev/null 2>&1 \
  || fail "CRD not present in the cluster - run 'make jit-up' before this checkpoint"

# --- 1. schema lists every new field (a field the schema omits is pruned) ----
for f in appliedParams attemptedParamsHash declaredBy; do
  grep -q "^\s*$f:" "$CRD" || fail "$f missing from $CRD status schema"
done
for cond in ParamsConflict AwaitingDeclarer NoDeclarer UpdateRefused Updating UpdateFailed OutputsChanged; do
  grep -q "$cond" "$CRD" || fail "condition $cond missing from $CRD"
done
# a printer column, so `kk get infraclaims` shows who declares
grep -q 'DECLARED' "$CRD" || fail "no DECLARED printer column in $CRD"

# --- 2. round-trip: the API server must not prune them ------------------------
existing="$(kk get infraclaims -A -o name 2>/dev/null | head -1 || true)"
[ -n "$existing" ] || fail "no InfraClaim exists to test the round-trip on - deploy the demo first"
# `kubectl get -o name` does not carry the namespace (kubectl v1.36); resolve it
# separately and name it on every call, or the patch lands in the current namespace
# and misses the claim (ADR 0011).
claim_ns="$(kk get infraclaims -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
claim_name="${existing##*/}"
[ -n "$claim_ns" ] && [ -n "$claim_name" ] \
  || fail "could not resolve the namespace/name of the round-trip claim ($existing)"
kk patch infraclaim "$claim_name" -n "$claim_ns" --type=merge --subresource=status -p '
  {"status":{"appliedParams":{"probe":"s25"},"attemptedParamsHash":"s25-probe-hash",
             "declaredBy":["probe-s25"]}}' >/dev/null \
  || fail "could not patch status - fields missing from the schema or the patch rejected"
sleep 2
for f in appliedParams attemptedParamsHash declaredBy; do
  kk get infraclaim "$claim_name" -n "$claim_ns" -o jsonpath="{.status.$f}" | grep -q "probe" \
    || fail "status.$f was pruned by the API server (add it to the CRD schema)"
done
echo "PASS S25: schema fields survive pruning; DECLARED printer column present"
