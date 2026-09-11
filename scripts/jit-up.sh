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

# The controller image must be in Docker *and* inside the cluster, and those are two
# different stores: `make destroy` deletes the k3d cluster and takes its containerd with
# it, so on a cold start the image is in Docker and nowhere else - and the rollout at the
# end of this script waits 180s only to fail on ImagePullBackOff. The earlier stages
# imported it by hand (S8); a cold host has nobody to do that.
docker image inspect jit-controller:latest >/dev/null 2>&1 \
  || fail "the 'jit-controller:latest' image is not built (docker build -t jit-controller jit-controller/)"

# Ask kubelet what its containerd holds rather than guessing - `k3d image list` takes no
# cluster flag in this version. If kubectl cannot answer, import: importing twice is
# harmless, a missing image is not.
cluster_has_image() {
  kubectl get nodes -o jsonpath='{.items[*].status.images[*].names[*]}' 2>/dev/null \
    | grep -q "$1"
}
if cluster_has_image 'jit-controller:latest'; then
  echo "jit-controller:latest is already in cluster '$CLUSTER'"
else
  echo "importing jit-controller:latest into cluster '$CLUSTER'..."
  k3d image import jit-controller:latest -c "$CLUSTER"
fi

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
