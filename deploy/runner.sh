#!/usr/bin/env bash
#
# deploy/runner.sh - Manage the containerised jit-runner at 172.19.0.10.
#
# Usage:
#   ./deploy/runner.sh build       Build the runner image (jit-runner:latest)
#   ./deploy/runner.sh up          Run the runner container at 172.19.0.10
#   ./deploy/runner.sh down        Stop and remove the runner container
#   ./deploy/runner.sh status      Show runner status
#   ./deploy/runner.sh logs        Show runner logs
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

IMAGE="jit-runner:latest"
CONTAINER="jit-runner"
RUNNER_IP="172.19.0.10"
CLUSTER_NET="k3d-voting-app"
MODULES_ROOT="$SCRIPT_DIR/jit-modules"
DOCKER_SOCKET="/var/run/docker.sock"
# A directory both the runner container and the Docker daemon can see. The runner
# passes it to tofu as TF_VAR_share_dir so the pgadmin module can bind-mount its
# servers.json into the pgadmin container; the daemon cannot read a file that only
# exists inside the runner's own filesystem (S17).
SHARE_DIR="${JIT_SHARE_DIR:-$HOME/.jit-host-share}"
mkdir -p "$SHARE_DIR"

if [[ -f "$SCRIPT_DIR/deploy/.env" ]]; then
  JIT_RUNNER_TOKEN="$(grep -E '^JIT_RUNNER_TOKEN=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2- || true)"
  MINIO_ENDPOINT="$(grep -E '^MINIO_ENDPOINT=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2- || true)"
  MINIO_BUCKET="$(grep -E '^MINIO_BUCKET=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2- || true)"
fi
: "${JIT_RUNNER_TOKEN:=s6-secret-token-2026}"
: "${MINIO_ENDPOINT:=http://172.19.0.11:9000}"
: "${MINIO_BUCKET:=jit-state}"

case "${1:-}" in
  build)
    echo "Building runner image..."
    docker build -t "$IMAGE" -f jit-runner/Dockerfile jit-runner/
    echo "Image built."
    ;;
  up)
    # NB: `docker inspect <name>` also matches the *image* of the same name, so scope
    # the check to containers explicitly.
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
      echo "Runner already running."
      echo "  (config or module changes need 'down' first: the container's mounts are fixed at creation)"
      exit 0
    fi
    echo "Starting runner at $RUNNER_IP (shared dir $SHARE_DIR)..."
    docker run -d \
      --name "$CONTAINER" \
      --network "$CLUSTER_NET" \
      --ip "$RUNNER_IP" \
      -v "$DOCKER_SOCKET:/var/run/docker.sock:ro" \
      -v "$MODULES_ROOT:/opt/jit-modules:ro" \
      -v "$SHARE_DIR:$SHARE_DIR" \
      -e "JIT_RUNNER_TOKEN=$JIT_RUNNER_TOKEN" \
      -e "DOCKER_HOST=unix:///var/run/docker.sock" \
      -e "MINIO_ENDPOINT=$MINIO_ENDPOINT" \
      -e "MINIO_BUCKET=$MINIO_BUCKET" \
      -e "JIT_SHARE_DIR=$SHARE_DIR" \
      -p 8100:8080 \
      "$IMAGE"
    echo "Runner started at $RUNNER_IP."
    ;;
  down)
    echo "Stopping runner..."
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "Runner stopped."
    ;;
  status)
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
      echo "Runner is running at $RUNNER_IP."
      docker ps | grep "$CONTAINER"
    else
      echo "Runner is not running."
    fi
    ;;
  logs)
    docker logs --tail 50 "$CONTAINER"
    ;;
  *)
    echo "Usage: $0 {build|up|down|status|logs}"
    ;;
esac