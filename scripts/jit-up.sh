#!/usr/bin/env bash
set -euo pipefail

# scripts/jit-up.sh - bring up the out-of-cluster half of the JIT stack.
#
#   make jit-up   ->   MinIO + runner + CRD + controller
#
# Order matters, and so does the last step: the controller's Python arrives as a
# ConfigMap mounted with subPath, and a subPath mount does not refresh when the
# ConfigMap changes, so the pod is recreated after the code is applied.
#
# Idempotent. The runner *is* recreated on every run: its mounts are fixed at
# creation time, and the pgadmin module depends on one of them (the shared
# directory the Docker daemon can also read, deploy/runner.sh).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CTRL_NS="default"
CTRL_DEPLOY="deployment/jit-controller"
CLUSTER="${CLUSTER:-voting-app}"

fail() { echo "FAIL: $1"; exit 1; }

for cmd in docker kubectl k3d; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is not on PATH"
done

k3d cluster list 2>/dev/null | grep -qE "^${CLUSTER}[[:space:]]" \
  || fail "k3d cluster '$CLUSTER' does not exist - create it first (app/scripts/deploy.sh)"

# The controller image is built and imported by the earlier stages (S8). Import it
# again only when Docker does not have it at all; a missing image inside the
# cluster surfaces below as a rollout failure naming the reason.
docker image inspect jit-controller:latest >/dev/null 2>&1 \
  || fail "the 'jit-controller:latest' image is not built (docker build -t jit-controller jit-controller/)"

# 1. MinIO - the Terraform state backend, 172.19.0.11, bucket jit-state.
./deploy/minio.sh

# 2. The runner at 172.19.0.10, holding the Docker socket. The image is rebuilt
#    every time: the runner's Python is baked into it (unlike the controller's,
#    which arrives as a mounted ConfigMap), so a stale image would silently run
#    old code. Docker's layer cache makes this cheap.
./deploy/runner.sh build
./deploy/runner.sh down
./deploy/runner.sh up

# 3. The CRD, before the controller starts watching it.
kubectl apply -f deploy/crd/infraclaim.yaml >/dev/null
kubectl wait --for condition=Established --timeout=60s crd/infraclaims.jit.io >/dev/null
echo "CRD infraclaims.jit.io established"

# 4. The controller: its own Deployment, RBAC and token Secret, then the real code.
kubectl apply -f deploy/controller.yaml >/dev/null
kubectl create configmap jit-controller-code -n "$CTRL_NS" \
  --from-file=main.py=jit-controller/main.py \
  --from-file=ipam.py=jit-controller/ipam.py \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete pod -l app=jit-controller -n "$CTRL_NS" --ignore-not-found --wait=true >/dev/null

if ! kubectl rollout status "$CTRL_DEPLOY" -n "$CTRL_NS" --timeout=180s; then
  echo "hint: if the pod is in ImagePullBackOff, the image is not inside the cluster:" >&2
  echo "      k3d image import jit-controller:latest -c $CLUSTER" >&2
  fail "the controller did not become Ready"
fi

# deploy/controller.yaml ships WATCH_NAMESPACES="" (cluster-wide) so the demo
# namespaces are reconciled without editing the Deployment again.
echo "controller Ready; watching: $(kubectl get "$CTRL_DEPLOY" -n "$CTRL_NS" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WATCH_NAMESPACES")].value}' || true)"
echo "PASS: jit stack up - MinIO, runner $(docker inspect -f '{{.State.Status}}' jit-runner), CRD, controller"
