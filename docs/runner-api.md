# Runner API Reference

The jit-runner is a FastAPI service that executes OpenTofu (Terraform) runs. It runs
outside the cluster on the Docker host, with direct access to the Docker socket and MinIO.

**Source:** [`jit-runner/main.py`](../jit-runner/main.py)

## Base URL

```
http://<runner-host>:8080
```

When deployed via `scripts/jit-up.sh`, the runner is accessible inside the k3d network at
the `jit-runner` Service IP, and on the host at `http://127.0.0.1:<mapped-port>`.

## Authentication

All endpoints require a bearer token (except `/health`):

```
Authorization: Bearer <JIT_RUNNER_TOKEN>
```

The token is set via the `JIT_RUNNER_TOKEN` environment variable. The controller includes
it in every request from `deploy/controller.yaml`.

## Endpoints

### `GET /health`

Liveness check. No auth required.

**Response** `200`:
```json
{"status": "ok"}
```

---

### `POST /v1/runs`

Execute `tofu apply` for a module. Creates or updates infrastructure.

**Request body:**
```json
{
  "module": "redis",
  "version": "main",
  "workspace": "voting-a",
  "params": {
    "name": "voting-a-redis",
    "network": "k3d-voting-app",
    "ip": "172.19.0.100"
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `module` | string | yes | Module name — must match a directory in `jit-modules/modules/` |
| `version` | string | no | Git ref for the module (default: `"main"`). Currently unused — modules are local files |
| `workspace` | string | yes | Namespace/workspace name — used as the state key and container name prefix |
| `params` | object | no | Key-value pairs passed as `-var` flags to tofu |

**Response** `200`:
```json
{
  "status": "applied",
  "outputs": {
    "address": "172.19.0.100",
    "port": "6379"
  },
  "error": null
}
```

| Status | Meaning |
|---|---|
| `applied` | `tofu apply` succeeded. `outputs` contains the module's Terraform outputs |
| `error` | `tofu init` or `tofu apply` failed. `error` contains the message |

The run is keyed by `(workspace, module)`. Concurrent requests for the same key are
serialised via an asyncio lock.

---

### `DELETE /v1/runs/{workspace}`

Execute `tofu destroy` for a workspace. Removes infrastructure.

**Path parameter:**
| Param | Description |
|---|---|
| `workspace` | The namespace/workspace to destroy |

**Request body** (optional):
```json
{
  "module": "redis",
  "params": {
    "name": "voting-a-redis",
    "network": "k3d-voting-app",
    "ip": "172.19.0.100"
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `module` | string | no | Module to destroy. If omitted, falls back to the workspace's single cached run |
| `params` | object | no | Same as POST — needed when there's no cached run |

**Module resolution order:**
1. If an in-memory cached run exists for `(workspace, module)` — use it (module + params
   from the original apply)
2. Else if `module` is provided in the request body — use it with the request's params
3. Else — return `not_found`

> [!WARNING]
> If `module` is omitted and the workspace has multiple cached runs (e.g., redis and
> postgres), the destroy will fail. Always specify `module` when calling from the
> controller — which it does.

**Response** `200`:
```json
{"status": "destroyed", "error": null}
```

| Status | Meaning |
|---|---|
| `destroyed` | Container removed, state cleaned, in-memory entry removed |
| `not_found` | No run found for the workspace and no module specified |
| `error` | `tofu init` or `tofu destroy` failed |

---

## Configuration (environment variables)

| Variable | Default | Description |
|---|---|---|
| `JIT_RUNNER_TOKEN` | `""` | Bearer token for auth |
| `JIT_MODULES_ROOT` | `../jit-modules/modules` (relative to runner source) | Path to module directories |
| `MINIO_ENDPOINT` | `http://127.0.0.1:9000` | S3-compatible state backend |
| `MINIO_BUCKET` | `jit-state` | Bucket for Terraform state |
| `MINIO_ACCESS_KEY` | `jit-state` | MinIO access key |
| `MINIO_SECRET_KEY` | `jit-state-secret-2026` | MinIO secret key |

## State management

Each `(workspace, module)` pair gets:
- A Terraform state file in MinIO at key `ns/<workspace>/<module>/terraform.tfstate`
- An in-memory entry tracking the work directory, outputs, status, and params
- A container named `<workspace>-<module>-<module>` (e.g., `voting-a-redis-redis`)

The in-memory registry is lost on runner restart. This is acceptable for the PoC — the
controller's resync will re-provision as needed. Production would persist this state.

## Error handling

- `tofu init` failures return `status: "error"` with the stderr message
- `tofu apply`/`destroy` failures do the same
- Container cleanup (`docker rm -f`) is attempted before destroy as a safety measure
- Failed destroys leave the workspace in a retryable state (the in-memory entry is kept)
- The runner logs every request with workspace and module for debugging