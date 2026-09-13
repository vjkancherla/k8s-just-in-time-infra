#!/usr/bin/env python3
"""
Serve the console page live on http://127.0.0.1:8090

    python3 console/serve.py        (Ctrl-C to stop)

GET  /                        -> console/index.html
GET  /state                   -> make state
GET  /log?name=x&offset=n     -> whatever the current run has written since n
POST /run/{name}              -> the command in ALLOWED, and nothing else

Output is written line by line to docs/evidence/console-{name}.log as it
happens, so both the terminal and the page fill while a long target runs
instead of waiting for it to finish.
"""

import functools
import http.server
import json
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

EVIDENCE = ROOT / "docs" / "evidence"
lock = threading.Lock()


def log_path(name):
    return EVIDENCE / f"console-{name}.log"


class Handler(http.server.SimpleHTTPRequestHandler):

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

        if path in ("/", "/index.html"):
            self.path = "/console/index.html"
        return super().do_GET()

    # ------------------------------------------------------------------ POST

    def do_POST(self):
        name = urlparse(self.path).path.rsplit("/", 1)[-1]
        cmd = ALLOWED.get(name)
        if not cmd:
            return self.send_json({"rc": 1, "out": f"{name} is not in the allowlist"}, 404)

        if not lock.acquire(blocking=False):
            return self.send_json({"rc": 1, "out": "another run is in progress"}, 409)

        try:
            EVIDENCE.mkdir(parents=True, exist_ok=True)
            path = log_path(name)
            print(f"--> {' '.join(cmd)}", flush=True)

            with path.open("w") as f:          # truncate before the page polls
                p = subprocess.Popen(cmd, cwd=ROOT, text=True,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT,
                                     bufsize=1)
                for line in p.stdout:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    f.write(line)
                    f.flush()
                rc = p.wait()

            print(f"<-- exit {rc}", flush=True)
            return self.send_json({"rc": rc, "out": ""})   # the page has it via /log
        except Exception as e:
            return self.send_json({"rc": 1, "out": f"could not run {name}: {e}"}, 500)
        finally:
            lock.release()


if __name__ == "__main__":
    handler = functools.partial(Handler, directory=str(ROOT))
    print(f"console on http://127.0.0.1:{PORT}   (Ctrl-C to stop)")
    try:
        http.server.ThreadingHTTPServer(("127.0.0.1", PORT), handler).serve_forever()
    except KeyboardInterrupt:
        print()
