"""jit-runner: out-of-cluster provisioning service.

FastAPI app that turns HTTP calls into tofu runs.
POST /v1/runs  → apply
DELETE /v1/runs/{workspace}  → destroy
Bearer token auth from JIT_RUNNER_TOKEN env var.
"""

import asyncio
import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

RUNNER_TOKEN = os.environ.get("JIT_RUNNER_TOKEN", "")
MODULES_ROOT = os.environ.get(
    "JIT_MODULES_ROOT",
    str(Path(__file__).resolve().parent.parent / "jit-modules" / "modules"),
)
MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", "http://127.0.0.1:9000")
MINIO_BUCKET = os.environ.get("MINIO_BUCKET", "jit-state")
MINIO_ACCESS_KEY = os.environ.get("MINIO_ACCESS_KEY", "jit-state")
MINIO_SECRET_KEY = os.environ.get("MINIO_SECRET_KEY", "jit-state-secret-2026")

# In-memory state, keyed by (workspace, module) so several modules can coexist in one
# namespace: {(workspace, module): {dir, outputs, status, params}}
_runs_lock = threading.Lock()
_runs: Dict[tuple, Dict[str, Any]] = {}
# One asyncio.Lock per run, so concurrent applies for the same (workspace, module) are
# serialised instead of racing over the same container name.
_run_locks_guard = threading.Lock()
_run_locks: Dict[tuple, asyncio.Lock] = {}


def _run_lock(key: tuple) -> asyncio.Lock:
    with _run_locks_guard:
        lock = _run_locks.get(key)
        if lock is None:
            lock = asyncio.Lock()
            _run_locks[key] = lock
        return lock

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="jit-runner", version="0.1.0")


class RunRequest(BaseModel):
    module: str
    version: str = "main"
    workspace: str
    params: Dict[str, str] = {}


class RunResponse(BaseModel):
    status: str
    outputs: Dict[str, str] = {}
    error: Optional[str] = None


class DestroyRequest(BaseModel):
    module: str = "redis"
    params: Dict[str, str] = {}


class DestroyResponse(BaseModel):
    status: str
    error: Optional[str] = None


def _check_auth(authorization: Optional[str]) -> None:
    if not RUNNER_TOKEN:
        return
    expected = f"Bearer {RUNNER_TOKEN}"
    if authorization != expected:
        raise HTTPException(status_code=401, detail="Unauthorized")


def _state_key(workspace: str, module: str) -> str:
    return f"ns/{workspace}/{module}/terraform.tfstate"


def _tofu_env() -> dict:
    env = os.environ.copy()
    env["AWS_ACCESS_KEY_ID"] = MINIO_ACCESS_KEY
    env["AWS_SECRET_ACCESS_KEY"] = MINIO_SECRET_KEY
    env["AWS_DEFAULT_REGION"] = "us-east-1"
    # Docker socket path (Rancher Desktop on macOS)
    if "DOCKER_HOST" not in env:
        if os.path.exists("/Users/vkancherla/.rd/docker.sock"):
            env["DOCKER_HOST"] = "unix:///Users/vkancherla/.rd/docker.sock"
        elif os.path.exists("/var/run/docker.sock"):
            env["DOCKER_HOST"] = "unix:///var/run/docker.sock"
    return env


def _run_tofu(args: list, cwd: str, env: dict) -> subprocess.CompletedProcess:
    return subprocess.run(
        args, cwd=cwd, capture_output=True, text=True, env=env, timeout=600,
    )


async def _run_tofu_async(args: list, cwd: str, env: dict) -> subprocess.CompletedProcess:
    """Run tofu in a thread to avoid blocking the event loop."""
    return await asyncio.to_thread(_run_tofu, args, cwd, env)


ANSI_RE = __import__("re").compile(r"\x1b\[[0-9;]*m")


def _strip_ansi(text: str) -> str:
    """Remove ANSI escape codes from text."""
    return ANSI_RE.sub("", text)


def _parse_outputs(stdout: str) -> Dict[str, str]:
    """Parse declared outputs from tofu apply or tofu output stdout.

    Looks for the 'Outputs:' section at the end of apply output and
    extracts key = value lines. Falls back to JSON parsing.
    """
    import json as _json
    clean = _strip_ansi(stdout)

    # Try JSON first (from tofu output -json)
    try:
        data = _json.loads(clean)
        if isinstance(data, dict):
            result = {}
            for k, v in data.items():
                if isinstance(v, dict) and "value" in v:
                    result[k] = str(v["value"])
            if result:
                return result
    except Exception:
        pass

    # Parse plain text output: key = value lines
    outputs: Dict[str, str] = {}
    for line in clean.splitlines():
        stripped = line.strip()
        if "=" in stripped:
            key, _, value = stripped.partition("=")
            key = key.strip()
            value = value.strip().strip('"')
            if key and value and key.isidentifier():
                outputs[key] = value
    return outputs


def _get_outputs(work_dir: str, env: dict) -> Dict[str, str]:
    """Run tofu output to get declared outputs only."""
    env_no_color = dict(env)
    env_no_color["NO_COLOR"] = "1"
    # Use plain text output — it only includes declared outputs
    r = _run_tofu(["tofu", "output", "-no-color"], work_dir, env_no_color)
    if r.returncode == 0 and r.stdout.strip():
        return _parse_outputs(r.stdout)
    return {}


@app.post("/v1/runs", response_model=RunResponse)
async def create_run(req: RunRequest, authorization: Optional[str] = Header(default=None)):
    """Apply a JIT module for a workspace. Idempotent."""
    _check_auth(authorization)

    key = (req.workspace, req.module)
    # Serialise per run: kopf fires on.create + on.update for one Deployment, and two
    # Deployments can annotate the same claim, so without this two tofu applies race
    # over the same container name.
    async with _run_lock(key):
        with _runs_lock:
            entry = _runs.get(key)
            if entry and entry["status"] == "success":
                return RunResponse(status="success", outputs=entry.get("outputs", {}))
        return await _apply_run(req, key)


async def _apply_run(req: RunRequest, key: tuple) -> RunResponse:
    """Run the apply and cache the result. The caller holds the run's lock."""
    work_dir = tempfile.mkdtemp(prefix=f"jit-{req.workspace}-")
    try:
        module_src = Path(MODULES_ROOT) / req.module
        if not module_src.is_dir():
            shutil.rmtree(work_dir, ignore_errors=True)
            return RunResponse(status="error",
                               error=f"Module '{req.module}' not found at {MODULES_ROOT}/{req.module}")

        for item in module_src.iterdir():
            shutil.copy2(item, work_dir)

        var_args: list = []
        for k, v in req.params.items():
            var_args.extend(["-var", f"{k}={v}"])

        env = _tofu_env()
        r = await _run_tofu_async(
            ["tofu", "init",
             "-backend-config", f"bucket={MINIO_BUCKET}",
             "-backend-config", f"key={_state_key(req.workspace, req.module)}",
             "-backend-config", f"endpoint={MINIO_ENDPOINT}",
             "-backend-config", f"access_key={MINIO_ACCESS_KEY}",
             "-backend-config", f"secret_key={MINIO_SECRET_KEY}",
             "-backend-config", "region=us-east-1",
             "-backend-config", "skip_credentials_validation=true",
             "-backend-config", "skip_metadata_api_check=true",
             "-backend-config", "force_path_style=true"]
            + var_args,
            work_dir, env,
        )
        if r.returncode != 0:
            shutil.rmtree(work_dir, ignore_errors=True)
            return RunResponse(status="error", error=f"tofu init failed: {r.stderr.strip()}")

        r = await _run_tofu_async(["tofu", "apply", "-auto-approve"] + var_args, work_dir, env)
        if r.returncode != 0:
            # If container name conflict, force-remove and retry
            if "already in use" in r.stderr:
                container_name = req.params.get("name", "")
                if container_name:
                    try:
                        subprocess.run(["docker", "rm", "-f", container_name],
                                       capture_output=True, timeout=30)
                    except Exception:
                        pass
                    r = await _run_tofu_async(
                        ["tofu", "apply", "-auto-approve"] + var_args, work_dir, env)
            if r.returncode != 0:
                shutil.rmtree(work_dir, ignore_errors=True)
                return RunResponse(status="error", error=f"tofu apply failed: {r.stderr.strip()}")

        outputs = _get_outputs(work_dir, env)

        with _runs_lock:
            _runs[key] = {"dir": work_dir, "module": req.module,
                          "status": "success", "outputs": outputs,
                          "params": req.params}

        return RunResponse(status="success", outputs=outputs)

    except Exception as e:
        shutil.rmtree(work_dir, ignore_errors=True)
        return RunResponse(status="error", error=str(e))


@app.delete("/v1/runs/{workspace}", response_model=DestroyResponse)
async def delete_run(workspace: str, body: DestroyRequest = None,
                     authorization: Optional[str] = Header(default=None)):
    """Destroy a JIT module for a workspace."""
    _check_auth(authorization)

    # Keyed by (workspace, module): a namespace can hold several modules, so destroy
    # must target the requested one rather than whichever was cached.
    with _runs_lock:
        key = (workspace, body.module if body else None)
        entry = _runs.get(key)
        if entry is None:
            candidates = [k for k in _runs if k[0] == workspace]
            if len(candidates) == 1:
                key = candidates[0]
                entry = _runs[key]

    if entry:
        work_dir = entry["dir"]
        module = entry["module"]
        params = entry.get("params", {})
    elif body:
        # No in-memory entry — use provided module/params
        module = body.module
        params = body.params
        work_dir = tempfile.mkdtemp(prefix=f"jit-destroy-{workspace}-")
        module_src = Path(MODULES_ROOT) / module
        if not module_src.is_dir():
            shutil.rmtree(work_dir, ignore_errors=True)
            return DestroyResponse(status="error",
                                   error=f"Module '{module}' not found")
        for item in module_src.iterdir():
            shutil.copy2(item, work_dir)
    else:
        return DestroyResponse(status="not_found",
                               error=f"No run found for workspace '{workspace}'")

    try:
        env = _tofu_env()

        # Safety: force-remove any existing container before destroy.
        # This handles the case where the container exists but tofu state is stale.
        container_name = f"{workspace}-{module}-{module}"
        try:
            subprocess.run(
                ["docker", "rm", "-f", container_name],
                capture_output=True, timeout=30,
            )
        except Exception:
            pass

        # Build var args for destroy (same as apply)
        var_args: list = []
        for k, v in params.items():
            var_args.extend(["-var", f"{k}={v}"])

        # Init backend before destroy (required for fresh work dirs)
        r = await _run_tofu_async(
            ["tofu", "init",
             "-backend-config", f"bucket={MINIO_BUCKET}",
             "-backend-config", f"key={_state_key(workspace, module)}",
             "-backend-config", f"endpoint={MINIO_ENDPOINT}",
             "-backend-config", f"access_key={MINIO_ACCESS_KEY}",
             "-backend-config", f"secret_key={MINIO_SECRET_KEY}",
             "-backend-config", "region=us-east-1",
             "-backend-config", "skip_credentials_validation=true",
             "-backend-config", "skip_metadata_api_check=true",
             "-backend-config", "force_path_style=true"]
            + var_args,
            work_dir, env,
        )
        if r.returncode != 0:
            return DestroyResponse(status="error",
                                   error=f"tofu init failed: {r.stderr.strip()}")

        r = await _run_tofu_async(["tofu", "destroy", "-auto-approve"] + var_args, work_dir, env)
        if r.returncode != 0:
            return DestroyResponse(status="error",
                                   error=f"tofu destroy failed: {r.stderr.strip()}")

        shutil.rmtree(work_dir, ignore_errors=True)
        with _runs_lock:
            _runs.pop(key, None)

        return DestroyResponse(status="destroyed")

    except Exception as e:
        shutil.rmtree(work_dir, ignore_errors=True)
        with _runs_lock:
            _runs.pop(key, None)
        return DestroyResponse(status="error", error=str(e))


@app.get("/health")
async def health():
    return {"status": "ok"}
