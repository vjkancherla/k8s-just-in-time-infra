#!/usr/bin/env bash
set -euo pipefail

# scripts/demo-up.sh - stand the demo up from cold (build-plan S18).
#
#   ./scripts/demo-up.sh voting-a              # make demo-up
#   ./scripts/demo-up.sh voting-a voting-b     # make test-up
#
# The order is the one docs/evidence/s17-cold-path-green.log established, and the names are
# the same targets S17 left green - this introduces no second cold path:
#
#   1. destroy     the cluster goes, and with it the app
#   2. jit-down    the module containers and the volumes they own outlive the cluster, and
#                  the addresses they hold are about to be handed out again by an empty ledger
#   3. deploy      creates the cluster, then stops by design until the CRD exists -
#                  app/scripts/deploy.sh exits non-zero there, and that is the expected
#                  outcome of this call, not a failure
#   4. jit-up      MinIO, runner, CRD, controller
#   5. the namespaces - an overlay sets a namespace, it does not create one
#   6. per namespace: deploy the app, then verify it with the target that fails
#
# Step 1 is why this is called the cold path, and it is load-bearing rather than
# tidy-mindedness. A claim is created by an event on the annotated Deployment, and a
# Deployment that is already running produces none: `kubectl apply` of an unchanged manifest
# is a no-op and kopf does not replay on.create for an object that already existed
# (scripts/jit-down.sh says the same, and documents "touch the Deployment" as the way a
# tenant comes back). `jit-down` destroys every claim, so a warm bring-up has to re-create
# them, and there are two ways: a touched Deployment, which leaves the pods it restarts
# holding the Secret as it was *before* the modules were re-provisioned, or a Deployment that
# does not exist yet. This script takes the second - the app is always applied after
# `jit-up`, so its claims come from create events and its pods are born after the controller
# has written the jit-* Services and Secrets. The first shape is not one this step can make
# correct, and it is not this step's to fix - it is the provisioning path
# (jit-controller/main.py, resolve_postgres_credentials) that writes the postgres password.
#
# Why step 6 does not use the app's own `make all`: that runs the app's `verify`, and
# app/scripts/verify.sh is a *report* - `set -uo pipefail` without `-e`, so it exits 0
# however many R-checks fail (build-plan S16/S17). A demo-up that reports success on a broken
# demo is not a gate, so the deploy half is the app's target and the verify half is the root
# target, which exits non-zero on a FAIL.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ $# -lt 1 ]]; then
  echo "FAIL: demo-up needs at least one namespace, e.g. 'make demo-up' or 'make test-up'" >&2
  exit 1
fi
NAMESPACES=("$@")

echo "== 1/6  cd app && make destroy   (the cold path: the app must be created after jit-up)"
( cd app && make destroy )

echo "== 2/6  make jit-down   (the containers and the volumes they own outlive the cluster)"
make jit-down

echo "== 3/6  cd app && make deploy   (creates the cluster; stops by design until the CRD exists)"
if ( cd app && make deploy ); then
  echo "   deploy ran to completion - the cluster and the CRD were both already there"
else
  echo "   deploy stopped before applying the app - expected while the CRD does not exist yet"
fi

echo "== 4/6  make jit-up"
make jit-up

echo "== 5/6  the namespaces (the overlays set one; they do not create one)"
for ns in "${NAMESPACES[@]}"; do
  kubectl create ns "$ns" 2>/dev/null || true
  kubectl get ns "$ns" >/dev/null 2>&1 \
    || { echo "FAIL: namespace $ns could not be created" >&2; exit 1; }
done

echo "== 6/7  deploy and verify the app, per namespace"
for ns in "${NAMESPACES[@]}"; do
  ( cd app && make deploy NS="$ns" KUSTOMIZE_DIR="./kustomize/overlays/$ns" )
  make verify NS="$ns"
  echo "   enabling demo mode for $ns"
  kubectl set env deployment/voting-app-vote ALLOW_MULTIPLE_VOTES=true -n "$ns"
  kubectl rollout status deployment/voting-app-vote -n "$ns" --timeout=120s
done

echo "== 7/7  demo mode enabled - ${NAMESPACES[*]}"
echo "PASS: demo up - ${NAMESPACES[*]}"
