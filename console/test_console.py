#!/usr/bin/env python3
"""
Tests that the console's three declarations agree, and that `make state` gives
the page what it renders.

    python3 console/test_console.py

Nothing here starts a server or needs a browser. It reads the Makefile, serve.py
and index.html as text, and runs `make state` once.

Why this file exists: every console bug so far has been a drift, not a logic
error. A target renamed in the Makefile but not the page. A field the page
renders that the read model stopped emitting. Neither shows up in a unit test of
either side, because each side is correct on its own.

Per docs/01-jit-poc.md these are a diagnostic tool, not proof. The checkpoint is
the proof.
"""

import json
import pathlib
import re
import subprocess
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import serve  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
MAKEFILE = ROOT / "Makefile"
PAGE = HERE / "index.html"

def reads():
    """Targets serve.py fetches for itself rather than offering as a button.

    Derived rather than listed, so adding an endpoint does not also mean
    remembering to edit this file. serve.py declares each read as an upper-case
    module constant holding a make invocation - STATE, CLAIM, and any that
    follow - and that is what this looks for.
    """
    found = set()
    for name, value in vars(serve).items():
        if not (name.isupper() and isinstance(value, list) and value[:1] == ["make"]):
            continue
        args = [a for a in value[1:] if not a.startswith("-")]
        if args:
            found.add(args[0])
    return found


# `targets` is the one read the page makes without going through serve.py.
NOT_BUTTONS = reads() | {"targets"}

# One name in ACTIONS can stand for a target called with different arguments.
# ns-delete-a and ns-delete-b are both `make ns-delete`, fenced by NS.
def target_of(action_name):
    return serve.ALLOWED[action_name][1]


class Declarations(unittest.TestCase):
    """The Makefile, serve.py and index.html have to agree on the names."""

    @classmethod
    def setUpClass(cls):
        cls.makefile = MAKEFILE.read_text()
        cls.page = PAGE.read_text()

        m = re.search(r"^CONSOLE_TARGETS\s*:=\s*(.+)$", cls.makefile, re.M)
        assert m, "no CONSOLE_TARGETS in the Makefile"
        cls.console_targets = m.group(1).split()

        cls.action_names = re.findall(r"\{mode:'[a-z]+',\s*name:'([^']+)'", cls.page)
        assert cls.action_names, "no ACTIONS found in index.html"

    def test_every_action_runs_an_allowlisted_command(self):
        for name in self.action_names:
            self.assertIn(name, serve.ALLOWED,
                          f"index.html offers '{name}', serve.py would 404 it")

    def test_every_allowed_command_is_offered_or_deliberately_not(self):
        for name in serve.ALLOWED:
            self.assertIn(name, self.action_names,
                          f"serve.py allows '{name}' but nothing on the page runs it")

    def test_every_allowed_command_is_a_target_the_makefile_publishes(self):
        for name in serve.ALLOWED:
            target = target_of(name)
            self.assertIn(target, self.console_targets,
                          f"'{name}' runs `make {target}`, which is not in CONSOLE_TARGETS")

    def test_every_published_target_is_reachable_or_a_read(self):
        reachable = {target_of(n) for n in serve.ALLOWED}
        for target in self.console_targets:
            if target in NOT_BUTTONS:
                continue
            self.assertIn(
                target, reachable,
                f"`make {target}` is in CONSOLE_TARGETS but nothing runs it.\n"
                f"  If the page fetches it, serve.py should hold it in an upper-case\n"
                f"  constant like STATE or CLAIM, and this test will find it.\n"
                f"  If you only run it by hand, take it out of CONSOLE_TARGETS -\n"
                f"  that list is what the console can reach.")

    def test_the_makefile_defines_every_target_it_publishes(self):
        for target in self.console_targets:
            rule = re.search(rf"^{re.escape(target)}\s*:", self.makefile, re.M)
            self.assertTrue(rule, f"CONSOLE_TARGETS lists '{target}' with no rule to run")

    def test_the_fence_is_declared_once(self):
        """ns-delete must not be reachable for a namespace outside TENANTS."""
        m = re.search(r"^TENANTS\s*:=\s*(.+)$", self.makefile, re.M)
        self.assertTrue(m, "no TENANTS fence in the Makefile")
        tenants = set(m.group(1).split())
        for name, cmd in serve.ALLOWED.items():
            for arg in cmd:
                if arg.startswith("NS="):
                    self.assertIn(arg[3:], tenants,
                                  f"'{name}' targets {arg}, outside TENANTS")


class Contract(unittest.TestCase):
    """`make state` has to carry every field the page renders."""

    @classmethod
    def setUpClass(cls):
        r = subprocess.run(serve.STATE, capture_output=True, text=True, cwd=ROOT)
        cls.raw, cls.stderr, cls.rc = r.stdout, r.stderr, r.returncode

    def state(self):
        try:
            return json.loads(self.raw)
        except Exception as e:
            self.fail(f"make state did not print JSON ({e})\n{self.stderr.strip()[:400]}")

    def test_it_exits_zero_whatever_the_cluster_is_doing(self):
        self.assertEqual(self.rc, 0, self.stderr.strip()[:400])

    def test_the_top_level_shape_is_the_same_up_or_down(self):
        d = self.state()
        for key in ("up", "generatedAt", "ingressPorts",
                    "namespaces", "containers", "stateObjects"):
            self.assertIn(key, d, f"the page reads '{key}' and it is not there")
        self.assertIsInstance(d["namespaces"], list)
        self.assertIsInstance(d["containers"], list)
        self.assertIsInstance(d["stateObjects"], list)
        self.assertIsInstance(d["ingressPorts"], dict)
        for scheme in ("http", "https"):
            self.assertIn(scheme, d["ingressPorts"])

    def test_every_namespace_carries_what_the_page_draws(self):
        for ns in self.state()["namespaces"]:
            for key in ("name", "block", "claims", "ingresses"):
                self.assertIn(key, ns, f"namespace is missing '{key}'")
            self.assertIsInstance(ns["claims"], list)
            self.assertIsInstance(ns["ingresses"], list)

    def test_every_claim_carries_what_the_page_draws(self):
        for ns in self.state()["namespaces"]:
            for claim in ns["claims"]:
                for key in ("module", "phase", "address", "referencedBy", "expiresAt"):
                    self.assertIn(key, claim, f"claim is missing '{key}'")
                self.assertIsInstance(claim["referencedBy"], list)

    def test_every_route_carries_what_the_app_panes_need(self):
        for ns in self.state()["namespaces"]:
            for route in ns["ingresses"]:
                for key in ("host", "path", "service", "tls"):
                    self.assertIn(key, route, f"route is missing '{key}'")
                self.assertIsInstance(route["tls"], bool)

    def test_an_orphaned_claim_has_something_to_count_down(self):
        """The countdown is the page's arithmetic on this field. Without it, no clock."""
        for ns in self.state()["namespaces"]:
            for claim in ns["claims"]:
                if claim["phase"] == "Orphaned":
                    self.assertTrue(claim["expiresAt"],
                                    f"{ns['name']}/{claim['module']} is Orphaned with no expiresAt")

    def test_a_running_stack_can_be_opened(self):
        """If the app is up, the page must be able to build a URL for it."""
        d = self.state()
        if not d["up"]:
            return
        routes = [r for ns in d["namespaces"] for r in ns["ingresses"]]
        if not routes:
            return          # jit-up without the app is a legitimate state
        self.assertTrue(
            any(d["ingressPorts"].get("https" if r["tls"] else "http") for r in routes),
            "there are routes but no published port, so no pane can load")


if __name__ == "__main__":
    unittest.main(verbosity=2)
