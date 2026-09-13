#!/usr/bin/env python3
"""
Tests for console/serve.py.

    python3 console/test_serve.py

These are behavioural, not unit tests: they start the real server on an ephemeral
port and talk to it over HTTP. There is almost no pure logic in serve.py to unit
test — it is routing and subprocesses — and the things that can actually go wrong
are all at the boundary.

No cluster is needed. ALLOWED is swapped for harmless commands, and the one test
that touches `make state` only asserts that a non-JSON answer degrades instead of
raising.

Per docs/01-jit-poc.md these are a diagnostic tool, not proof the console works.
The checkpoint is the proof.
"""

import json
import pathlib
import sys
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import serve  # noqa: E402


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def post(url):
    req = urllib.request.Request(url, method="POST", data=b"")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class ConsoleServer(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        # never run a real target from a test
        cls.real_allowed = serve.ALLOWED
        serve.ALLOWED = {
            "hello":  ["python3", "-c", "print('line one'); print('line two')"],
            "failing": ["python3", "-c", "import sys; sys.exit(3)"],
        }
        cls.server = serve.build_server(0)
        cls.base = "http://127.0.0.1:%d" % cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        serve.ALLOWED = cls.real_allowed

    # ---------------------------------------------------------------- page

    def test_root_serves_the_page(self):
        status, body = get(self.base + "/")
        self.assertEqual(status, 200)
        self.assertIn("<title>JIT Console</title>", body)

    def test_the_repo_is_not_served(self):
        """
        The regression this file exists for. ROOT holds deploy/.env and
        app/kustomize/postgres-secret.env; the console must never hand out a
        file from it.
        """
        for path in ["/deploy/.env",
                     "/app/kustomize/postgres-secret.env",
                     "/Makefile",
                     "/console/serve.py",
                     "/../../etc/passwd",
                     "/docs/evidence/",
                     "/%2e%2e/%2e%2e/etc/passwd"]:
            status, _ = get(self.base + path)
            self.assertEqual(status, 404, f"{path} was served")

    # ----------------------------------------------------------- allowlist

    def test_an_allowlisted_name_runs(self):
        status, body = post(self.base + "/run/hello")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["rc"], 0)

    def test_an_unknown_name_is_refused(self):
        status, body = post(self.base + "/run/rm-rf-slash")
        self.assertEqual(status, 404)
        self.assertIn("allowlist", json.loads(body)["out"])

    def test_a_real_target_name_is_still_refused_if_not_allowlisted(self):
        """A target existing in the Makefile is not enough to make it reachable."""
        status, _ = post(self.base + "/run/jit-down")
        self.assertEqual(status, 404)

    def test_a_failing_command_keeps_its_exit_code(self):
        status, body = post(self.base + "/run/failing")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["rc"], 3)

    # ----------------------------------------------------------------- log

    def test_output_reaches_the_log_endpoint(self):
        post(self.base + "/run/hello")
        status, body = get(self.base + "/log?name=hello&offset=0")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertIn("line one", payload["text"])
        self.assertEqual(payload["offset"], len(payload["text"]))

    def test_the_log_offset_returns_only_what_is_new(self):
        post(self.base + "/run/hello")
        _, first = get(self.base + "/log?name=hello&offset=0")
        offset = json.loads(first)["offset"]
        _, second = get(self.base + f"/log?name=hello&offset={offset}")
        self.assertEqual(json.loads(second)["text"], "")

    def test_the_log_of_an_unknown_name_is_empty(self):
        """Otherwise /log is a second way to read arbitrary files."""
        status, body = get(self.base + "/log?name=../../../etc/passwd&offset=0")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["text"], "")

    def test_a_rerun_truncates_the_previous_log(self):
        post(self.base + "/run/hello")
        post(self.base + "/run/failing")
        _, body = get(self.base + "/log?name=failing&offset=0")
        self.assertNotIn("line one", json.loads(body)["text"])

    # --------------------------------------------------------------- state

    def test_state_always_answers_with_an_object(self):
        """
        Whatever `make state` does — succeed, fail, or not exist — the page must
        get JSON with an `up` key, because it polls this before anything exists.
        """
        real = serve.STATE
        try:
            serve.STATE = ["python3", "-c", "print('not json at all')"]
            status, body = get(self.base + "/state")
            self.assertEqual(status, 200)
            self.assertIs(json.loads(body)["up"], False)

            serve.STATE = ["python3", "-c", "import sys; sys.exit(1)"]
            status, body = get(self.base + "/state")
            self.assertEqual(status, 200)
            self.assertIs(json.loads(body)["up"], False)
        finally:
            serve.STATE = real

    def test_state_passes_json_through_untouched(self):
        real = serve.STATE
        try:
            serve.STATE = ["python3", "-c",
                           "print('{\"up\": true, \"namespaces\": [{\"name\": \"voting-a\"}]}')"]
            _, body = get(self.base + "/state")
            payload = json.loads(body)
            self.assertIs(payload["up"], True)
            self.assertEqual(payload["namespaces"][0]["name"], "voting-a")
        finally:
            serve.STATE = real

    # --------------------------------------------------------------- claim

    def test_claim_rejects_anything_that_is_not_a_name(self):
        for q in ["ns=voting-a&module=../../etc/passwd",
                  "ns=&module=redis",
                  "ns=voting-a&module=",
                  "ns=voting-a&module=NS=default",
                  "ns=voting%20a&module=redis",   # a space, encoded so urllib will send it
                  "ns=voting-a&module=redis;rm"]:
            status, _ = get(self.base + "/claim?" + q)
            self.assertEqual(status, 400, f"{q} was accepted")

    def test_claim_passes_a_valid_name_through(self):
        real = serve.CLAIM
        try:
            serve.CLAIM = ["python3", "-c",
                           "import sys; print('kind: InfraClaim'); print(sys.argv[1:])", "--"]
            status, body = get(self.base + "/claim?ns=voting-a&module=redis")
            self.assertEqual(status, 200)
            payload = json.loads(body)
            self.assertIn("kind: InfraClaim", payload["text"])
            self.assertIn("NS=voting-a", payload["text"])
            self.assertIn("MODULE=redis", payload["text"])
        finally:
            serve.CLAIM = real

    def test_claim_reports_a_failure_instead_of_raising(self):
        real = serve.CLAIM
        try:
            serve.CLAIM = ["python3", "-c",
                           "import sys; sys.stderr.write('not found'); sys.exit(1)"]
            status, body = get(self.base + "/claim?ns=voting-a&module=redis")
            self.assertEqual(status, 200)
            self.assertIn("not found", json.loads(body)["error"])
        finally:
            serve.CLAIM = real

    # --------------------------------------------------------------- lock

    def test_one_run_at_a_time(self):
        real = serve.ALLOWED["hello"]
        try:
            serve.ALLOWED["hello"] = ["python3", "-c", "import time; time.sleep(2)"]
            codes = []
            threads = [threading.Thread(
                target=lambda: codes.append(post(self.base + "/run/hello")[0]))
                for _ in range(2)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            self.assertIn(409, codes, "two runs were allowed at once")
            self.assertIn(200, codes)
        finally:
            serve.ALLOWED["hello"] = real


class Allowlist(unittest.TestCase):
    """The static properties of the allowlist, checked without a server."""

    def test_every_command_is_a_list(self):
        for name, cmd in serve.ALLOWED.items():
            self.assertIsInstance(cmd, list, f"{name} is not a list — no shell strings")
            self.assertTrue(all(isinstance(x, str) for x in cmd))

    def test_nothing_goes_through_a_shell(self):
        for name, cmd in serve.ALLOWED.items():
            joined = " ".join(cmd)
            for meta in ["&&", "||", ";", "|", ">", "`", "$("]:
                self.assertNotIn(meta, joined, f"{name} contains {meta}")

    def test_every_action_is_a_make_target(self):
        """The console runs no kubectl of its own — that is the whole design rule."""
        for name, cmd in serve.ALLOWED.items():
            self.assertEqual(cmd[0], "make", f"{name} does not run make")


if __name__ == "__main__":
    unittest.main(verbosity=2)
