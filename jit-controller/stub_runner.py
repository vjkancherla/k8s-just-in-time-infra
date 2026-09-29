#!/usr/bin/env python3
"""S26 stub runner.

A stand-in for the real `jit-runner` that S26 exercises the controller against:
it records every provisioning call and can be told to fail, without touching
Terraform or Docker. The controller is started with
`RUNNER_URL=http://127.0.0.1:8999`, so `call_runner` posts here.

Contract used by `scripts/checks/S26.sh`:

- `POST /v1/runs` logs one line per call, exactly
  `POST module=<module> workspace=<workspace>`, which the checkpoint greps with
  `stub_get`. It answers `{"status": "success", "outputs": {...}}`, or
  `{"status": "error", "error": ...}` while fail mode is on.
- `POST /mode/fail` and `POST /mode/ok` toggle fail mode.
- `DELETE /v1/runs/<workspace>` answers `{"status": "destroyed"}`.

The checkpoint owns the process and its log path: it passes `STUB_LOG` and kills
the process on exit. Nothing else in the repo starts this file.
"""

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("STUB_PORT", "8999"))
LOG_PATH = os.environ.get("STUB_LOG", "")

_lock = threading.Lock()
_log_lock = threading.Lock()
_fail_mode = False


def _log(line):
    with _log_lock:
        if LOG_PATH:
            with open(LOG_PATH, "a") as fh:
                fh.write(line + "\n")
                fh.flush()


def _record(kind, module, workspace):
    if kind == "POST":
        _log(f"POST module={module} workspace={workspace}")
    else:
        _log(f"{kind} module={module} workspace={workspace}")


def _outputs(module, params):
    addr = str(params.get("ip", ""))
    if "pgadmin" in module:
        port = "5050"
    elif "postgres" in module:
        port = "5432"
    else:
        port = "6379"
    return {"address": addr, "port": port}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # the checkpoint reads STUB_LOG, not the server's stderr

    def _reply(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return {}

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"status": "ok"})
        else:
            self._reply(404, {"status": "error", "error": "not found"})

    def do_POST(self):
        global _fail_mode
        if self.path == "/mode/fail":
            with _lock:
                _fail_mode = True
            self._reply(200, {"status": "ok", "mode": "fail"})
            return
        if self.path == "/mode/ok":
            with _lock:
                _fail_mode = False
            self._reply(200, {"status": "ok", "mode": "ok"})
            return
        if self.path == "/v1/runs":
            body = self._read_json()
            module = str(body.get("module", ""))
            workspace = str(body.get("workspace", ""))
            params = body.get("params", {}) or {}
            # The workspace substring the checkpoint's stale comment mentions;
            # kept so a workspace named "*s26fail*" can pin a failure too.
            with _lock:
                fail = _fail_mode or "s26fail" in workspace
            _record("POST", module, workspace)
            if fail:
                self._reply(200, {"status": "error",
                                  "error": f"stub failure for {workspace}/{module}"})
            else:
                self._reply(200, {"status": "success",
                                  "outputs": _outputs(module, params)})
            return
        self._reply(404, {"status": "error", "error": "not found"})

    def do_DELETE(self):
        parts = self.path.split("/")
        workspace = parts[-1] if len(parts) >= 4 else ""
        module = ""
        body = self._read_json()
        module = str(body.get("module", ""))
        _record("DELETE", module, workspace)
        self._reply(200, {"status": "destroyed", "error": None})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
