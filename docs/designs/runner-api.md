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
| `params` | object | no | Arbitrary JSON values passed as `-var` flags: a string is passed verbatim, a list/object/number is JSON-encoded (valid HCL) |

**Response** `200`:
```json
{
  "status": "success",
  "outputs": {
    "address": "172.19.0.100",
    "port": "6379"
  },
  "error": null
}
```

| Status | Meaning |
|---|---|
| `success` | `tofu apply` succeeded, or an identical re-POST returned the cached success. `outputs` contains the module's Terraform outputs |
| `error` | `tofu init` or `tofu apply` failed. `error` contains the message |

The run is keyed by `(workspace, module)`. Concurrent requests for the same key are
serialised via an asyncio lock.

The success cache is keyed on the **hash of module + workspace + params**. A re-POST whose
hash matches the last success returns the cached `outputs` without running tofu (the
identifier the controller's update flow relies on); a changed hash is a real re-apply. A
changed-params apply replaces the cached entry and removes the previous run's work dir.

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
| `params` | object | no | Same shape as POST (`Dict[str, Any]` — lists/objects/numbers allowed). Needed when there is no cached run, and for a module whose tofu needs its vars to destroy |

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
| `error` | `tofu init`, `tofu state list`, `tofu state rm` or `tofu destroy` failed |

The destroy holds the same per-run lock as POST, so an apply and a destroy for one
`(workspace, module)` cannot interleave. Before destroying, the runner reads the state with
`tofu state list` and drops every `postgresql_*` resource with `tofu state rm` (the postgres
module's logical databases cannot be destroyed once their server is gone). A state that
cannot be read is a refusal, not a silent skip; a workspace with no state file at all is an
empty destroy and succeeds.

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
controller's resync will re-provision as needed. Production would persist this state. On
startup the runner sweeps every orphan `jit-*` work dir under the temp root, since a
restart makes them unreachable (a plain `docker start` keeps the container's `/tmp` but
loses `_runs`; `make jit-up` recreates the container).

## Error handling

- `tofu init` failures return `status: "error"` with the stderr message
- `tofu apply`/`destroy` failures do the same
- A `tofu state list` failure returns `status: "error"` rather than proceeding without the
  `state rm` (a workspace with no state file is the one exception, treated as empty)
- Container cleanup (`docker rm -f`) is attempted before destroy as a safety measure
- Failed destroys leave the workspace in a retryable state (the in-memory entry is kept)
- Work-dir removal is best-effort but logged, so a leaked directory leaves a trace
- The runner logs every request with workspace and module for debugging