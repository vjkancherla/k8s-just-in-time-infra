# 0002. Runner as a separate HTTP service

Date: 2026-09-01
Status: accepted

## Context

Infrastructure provisioning (tofu apply/destroy) needs Docker socket access and Terraform
state credentials. Running this inside the controller pod would:

1. Put credentials (MinIO keys, Docker socket) inside the cluster.
2. Couple the controller's Python lifecycle to OpenTofu's binary and module layout.
3. Make modules harder to version — they'd be baked into the controller image.

## Decision

A separate **runner** service (FastAPI, deployed outside the cluster via Docker) exposes
an HTTP API:

- `POST /v1/runs` — apply a module
- `DELETE /v1/runs/{workspace}` — destroy a module
- `GET /health` — liveness

The controller calls the runner over HTTP with a bearer token. The runner owns the Docker
socket and MinIO credentials; the controller never touches either.

The runner has a configurable `MODULES_ROOT` (defaults to `jit-modules/modules/` relative
to the runner source) and a `JIT_RUNNER_TOKEN` for auth. When a destroy request omits the
module, the runner falls back to the workspace's single cached run from its in-memory
registry — but only when no explicit module was provided. This prevents a race where the
TTL sweep's destroy (no module specified) resolves to the wrong cached module.

## Consequences

- **Easy**: Credentials stay outside the cluster. Modules can be versioned independently.
  The runner can be restarted without touching the controller. The HTTP boundary makes
  the contract explicit and testable.
- **Hard**: Two services to deploy instead of one. The runner's in-memory run registry is
  lost on restart (acceptable for a PoC; production would use persistent state).
- **Ruled out**: Modules in the controller image (v1). Sidecar with shared filesystem.
  Async queue (correct for production but too much scope for the PoC).

See [the design note](../jit-infra-poc.md#the-split-plane) and
[the runner source](../../jit-runner/main.py) for details.