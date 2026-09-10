#!/usr/bin/env bash
#
# Checkpoint S1 - The design's one hard gate.
#
# Prove that a pod in the k3d cluster can reach a container by its Docker-network IP.
# This is the single assumption the whole JIT design rests on: pod traffic to a
# non-cluster CIDR routes out through the node and k3s masquerades it. If it fails,
# STOP and report - do not work around it. The fallback (host port +
# host.k3d.internal) turns IPAM into port allocation and needs a design amendment
# first.
#
# Run from the work root (k8s-just-in-time-infra/):
#     ./scripts/checks/S01.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CLUSTER_NET="k3d-voting-app"
PROBE_IP="172.19.0.100"
PHASE="unknown"

# Always clean up our probe artifacts, on success or failure.
cleanup() {
  kubectl delete pod probe --ignore-not-found --timeout=10s >/dev/null 2>&1 || true
  docker rm -f probe-redis >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $1"; exit 1; }

# 1. A redis container sitting at the fixed Docker-network IP.
docker rm -f probe-redis >/dev/null 2>&1 || true
docker run -d --name probe-redis \
  --network "$CLUSTER_NET" --ip "$PROBE_IP" \
  redis:7-alpine >/dev/null 2>&1 \
  || fail "could not start probe-redis at $PROBE_IP on $CLUSTER_NET"

# Give redis a moment to start listening.
sleep 3

# 2. From inside the cluster, reach that Docker-network IP.
kubectl run probe --restart=Never --image=redis:7-alpine \
  -- redis-cli -h "$PROBE_IP" ping >/dev/null 2>&1 \
  || fail "could not launch probe pod"

# Wait for the one-shot pod to finish, then read its output.
for _ in $(seq 1 30); do
  PHASE=$(kubectl get pod probe -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Completed" || "$PHASE" == "Failed" ]] && break
  sleep 2
done
out=$(kubectl logs probe 2>/dev/null || echo "")

# 3. The gate: the pod saw PONG back from $PROBE_IP.
[[ "$out" == *"PONG"* ]] \
  || fail "probe did not get PONG from $PROBE_IP (got: '${out:-<none>}' / phase='${PHASE:-<unknown>}')"

echo "PASS: pod reached $PROBE_IP on $CLUSTER_NET and redis-cli returned PONG"
