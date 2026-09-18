#!/usr/bin/env python3
"""
Serve the console page live on http://127.0.0.1:8090

    python3 console/serve.py        (Ctrl-C to stop)

GET  /                        -> console/index.html
GET  /state                   -> make state
GET  /claim?ns=&module=       -> make claim (one InfraClaim as YAML)
GET  /timeline                -> make timeline (the run as one JSON document)
GET  /log?name=x&offset=n     -> whatever the current run has written since n
POST /run/{name}              -> the command in ALLOWED, and nothing else

Output is written line by line to docs/evidence/console-{name}.log as it
happens, so both the terminal and the page fill while a long target runs
instead of waiting for it to finish.
"""

import http.server
import json
import re
import pathlib
import subprocess
import sys
import threading
from urllib.parse import urlparse, parse_qs

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
PORT = 8090

# ---------------------------------------------------------------------------
# EDIT THIS. Keys match the `name` values in index.html's ACTIONS list; values
# are what actually runs, from ROOT. Nothing outside this dict can be executed,
# so a typo in the page is a 404 rather than a surprise.
# ---------------------------------------------------------------------------
ALLOWED = {
    "demo-up":      ["make", "demo-up"],
    "demo-undeploy": ["make", "demo-undeploy"],
    "demo-redeploy": ["make", "demo-redeploy"],
    "ns-delete-a":  ["make", "ns-delete", "NS=voting-a"],
    "test-up":      ["make", "test-up"],
    "jit-up":       ["make", "jit-up"],
    "verify":       ["make", "verify", "NS=voting-a"],
    "jit-verify":   ["make", "jit-verify"],
    "ns-delete-b":  ["make", "ns-delete", "NS=voting-b"],
    "jit-down":     ["make", "jit-down"],
    "destroy":      ["make", "destroy"],
}

STATE = ["make", "-s", "state"]
CLAIM = ["make", "-s", "claim"]
TIMELINE = ["make", "-s", "timeline"]

# NS and MODULE are interpolated into a make invocation, so they are checked
# rather than trusted. Nothing goes through a shell, but a stray "=" or ".."
# would still reach make as something it did not expect.
SAFE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

EVIDENCE = ROOT / "docs" / "evidence"
lock = threading.Lock()


def log_path(name):
    return EVIDENCE / f"console-{name}.log"


class Handler(http.server.BaseHTTPRequestHandler):

    # ------------------------------------------------------------------ util

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass          # the interesting output is the --> line below

    # ------------------------------------------------------------------- GET

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/state":
            r = subprocess.run(STATE, capture_output=True, text=True, cwd=ROOT)
            try:
                return self.send_json(json.loads(r.stdout))
            except Exception as e:
                print(f"!!! make state did not return JSON: {e}", flush=True)
                if r.stderr.strip():
                    print(r.stderr.strip(), flush=True)
                return self.send_json({"up": False, "namespaces": [],
                                       "containers": [], "stateObjects": []})

        if path == "/claim":
            q = parse_qs(urlparse(self.path).query)
            ns = q.get("ns", [""])[0]
            module = q.get("module", [""])[0]
            if not (SAFE.match(ns) and SAFE.match(module)):
                return self.send_json({"text": "", "error": "bad ns or module"}, 400)
            r = subprocess.run(CLAIM + [f"NS={ns}", f"MODULE={module}"],
                               capture_output=True, text=True, cwd=ROOT)
            return self.send_json({"text": r.stdout,
                                   "error": "" if r.returncode == 0 else r.stderr.strip()})

        if path == "/log":
            q = parse_qs(urlparse(self.path).query)
            name = q.get("name", [""])[0]
            offset = int(q.get("offset", ["0"])[0])
            p = log_path(name)
            text = ""
            if name in ALLOWED and p.exists():
                try:
                    text = p.read_text()[offset:]
                except Exception:
                    text = ""
            return self.send_json({"text": text,
                                   "offset": offset + len(text),
                                   "running": lock.locked()})

        if path == "/timeline":
            r = subprocess.run(TIMELINE, capture_output=True, text=True, cwd=ROOT)
            try:
                return self.send_json(json.loads(r.stdout))
            except Exception:
                return self.send_json({"up": False, "t0": None, "events": []})

        if path in ("/", "/index.html"):
            try:
                body = (HERE / "index.html").read_bytes()
            except Exception:
                return self.send_error(500, "console/index.html is missing")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)

        # Nothing else is served. This process must never hand out repo files:
        # deploy/.env and app/kustomize/postgres-secret.env live under ROOT.
        return self.send_error(404)

    # ------------------------------------------------------------------ POST

    def do_POST(self):
        name = urlparse(self.path).path.rsplit("/", 1)[-1]
        cmd = ALLOWED.get(name)
        if not cmd:
            return self.send_json({"rc": 1, "out": f"{name} is not in the allowlist"}, 404)

        if not lock.acquire(blocking=False):
            return self.send_json({"rc": 1, "out": "another run is in progress"}, 409)

        # The lock is released before the response is sent. Releasing in a
        # `finally` after send_json leaves a window where the client has been
        # told the run finished but the next one is still refused with a 409.
        try:
            EVIDENCE.mkdir(parents=True, exist_ok=True)
            path = log_path(name)
            print(f"--> {' '.join(cmd)}", flush=True)

            with path.open("w") as f:
                p = subprocess.Popen(cmd, cwd=ROOT, text=True,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT,
                                     bufsize=1)
                with p.stdout:
                    for line in p.stdout:
                        sys.stdout.write(line)
                        sys.stdout.flush()
                        f.write(line)
                        f.flush()
                rc = p.wait()

            print(f"<-- exit {rc}", flush=True)
            result, code = {"rc": rc, "out": ""}, 200   # the page has it via /log
        except Exception as e:
            result, code = {"rc": 1, "out": f"could not run {name}: {e}"}, 500
        finally:
            lock.release()

        return self.send_json(result, code)


def build_server(port=PORT):
    """Separated so the tests can start one on an ephemeral port."""
    return http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    print(f"console on http://127.0.0.1:{PORT}   (Ctrl-C to stop)")
    try:
        build_server().serve_forever()
    except KeyboardInterrupt:
        print()
