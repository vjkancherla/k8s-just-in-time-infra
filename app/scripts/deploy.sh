#!/usr/bin/env bash
set -euo pipefail

# Create the k3d cluster (if missing), build + load images, and apply the
# kustomize manifests.
#
# Local access notes:
#   - vote.localhost and result.localhost are routed by the ingress through the k3d
#     loadbalancer on host ports 8081 (HTTP) and 8082 (HTTPS). The *.localhost TLD
#     resolves to 127.0.0.1 natively (RFC 6761) — no /etc/hosts entry and no external
#     DNS (nip.io) required. Just open the URLs below in a browser or curl.
#   - Then open https://vote.localhost:8082/ and
#     https://result.localhost:8082/
#
# Registry mode (REGISTRY=1): create the cluster with --registry-create and
# apply kustomize/overlays/registry, which points image refs at the
# cluster-internal registry hostname (default port 5000; edit the overlay to
# 5001 if AirPlay Receiver claims port 5000). Uses scripts/build.sh, which must
# also run with REGISTRY=1 (this script passes it).

CLUSTER="${CLUSTER:-voting-app}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-./kustomize}"
REGISTRY="${REGISTRY:-0}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

# 1. Create the cluster if it does not already exist.
if ! k3d cluster list 2>/dev/null | grep -qE "^${CLUSTER}[[:space:]]"; then
  args=(cluster create "$CLUSTER" -p "8081:80@loadbalancer" -p "8082:443@loadbalancer" --agents 1 --subnet 172.19.0.0/16)
  if [[ "$REGISTRY" == "1" ]]; then
    args+=(--registry-create "voting-app-registry.localhost:${REGISTRY_PORT}")
  fi
  k3d "${args[@]}"
fi

# 2. Build and load the application images.
REGISTRY="$REGISTRY" REGISTRY_PORT="$REGISTRY_PORT" CLUSTER="$CLUSTER" ./scripts/build.sh

# 3. The app has no stateful workload in the cluster: its pods consume the
#    controller-written jit-redis / jit-postgres Services, and the Postgres
#    password comes from the jit-postgres Secret. Without the JIT stack the pods
#    sit in Init until the 300s timeout, so fail fast with the real reason.
if ! kubectl get crd infraclaims.jit.io >/dev/null 2>&1; then
  echo "error: the InfraClaim CRD is not installed - the JIT stack must be up first." >&2
  echo "       Bring up MinIO, the runner, the CRD and the controller" >&2
  echo "       (deploy/minio.sh, deploy/controller.yaml) and re-run." >&2
  exit 1
fi

# 4. Apply the manifests.
if [[ "$REGISTRY" == "1" ]]; then
  kubectl apply -k "${KUSTOMIZE_DIR}/overlays/registry"
else
  kubectl apply -k "${KUSTOMIZE_DIR}"
fi

# 5. Wait for the application workloads. There are three of them: the app has no
#    stateful workload in the cluster any more. Redis, Postgres and pgAdmin are
#    provisioned out of cluster by the JIT controller + runner, so these pods
#    stay in Init until the controller has written the jit-redis / jit-postgres
#    Services and Secrets.
kubectl rollout status deployment voting-app-vote --timeout=300s
kubectl rollout status deployment voting-app-worker --timeout=300s
kubectl rollout status deployment voting-app-result --timeout=300s

echo "Deploy complete."
echo "  vote:   https://vote.localhost:8082/   (*.localhost resolves to 127.0.0.1 natively — no /etc/hosts needed)"
echo "  result: https://result.localhost:8082/"

