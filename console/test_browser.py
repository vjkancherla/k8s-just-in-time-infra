#!/usr/bin/env python3
"""
Browser tests for the console.

    pip install playwright && playwright install chromium
    python3 console/test_browser.py              # run the tests
    python3 console/test_browser.py --shots      # write a PNG per state to console/shots/

No cluster is needed, and that is the point. `serve.py` gets its data by running
a command, so these tests point that command at a fixture file. The console can
therefore be put into states a real cluster would take twenty minutes to reach,
and into states it is hard to produce on purpose at all - a failed claim, a
namespace with no routes, a claim whose clock has four seconds left.

`--shots` is the other half of the value: one command renders every state as a
picture, so eight permutations can be reviewed by eye in ten seconds instead of
being clicked through by hand.

ALLOWED is swapped for harmless commands, so no test can start or destroy
anything.

Per docs/01-jit-poc.md these are a diagnostic tool, not proof. The checkpoint is
the proof.
"""

import json
import pathlib
import sys
import threading
import time
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import serve  # noqa: E402

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sys.exit("playwright is not installed:\n"
             "    pip install playwright && playwright install chromium")

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
SHOTS = HERE / "shots"


# --------------------------------------------------------------- fixtures

def when(seconds_from_now):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ",
                         time.gmtime(time.time() + seconds_from_now))


def claim(module, phase, address, refs=(), expires=None):
    return {"module": module, "phase": phase, "address": address,
            "referencedBy": list(refs), "expiresAt": expires}


def route(host, service, tls=True):
    return {"host": host, "path": "/", "service": service, "tls": tls}


def state(up=True, namespaces=(), containers=(), objects=(), ports=None):
    return {"up": up,
            "generatedAt": when(0),
            "ingressPorts": ports if ports is not None else {"http": 8081, "https": 8082},
            "namespaces": list(namespaces),
            "containers": list(containers),
            "stateObjects": list(objects)}


def voting_a(claims, routes=True):
    return {"name": "voting-a",
            "block": "172.19.0.100-109",
            "claims": claims,
            "ingresses": [route("vote.localhost", "voting-app-vote"),
                          route("result.localhost", "voting-app-result")] if routes else []}


READY = [claim("pgadmin", "Ready", "172.19.0.100", ["vote"]),
         claim("postgres", "Ready", "172.19.0.102", ["vote", "worker"]),
         claim("redis", "Ready", "172.19.0.101", ["vote", "worker"])]

CONTAINERS = [{"name": "voting-a-redis-redis", "address": "172.19.0.101", "running": True},
              {"name": "voting-a-postgres-postgres", "address": "172.19.0.102", "running": True},
              {"name": "voting-a-pgadmin-pgadmin", "address": "172.19.0.100", "running": True}]

OBJECTS = ["ns/voting-a/postgres/terraform.tfstate",
           "ns/voting-a/redis/terraform.tfstate"]

def states():
    """Built on every call: the timestamps in them are relative to now."""
    return {
        "down": state(up=False, ports={"http": None, "https": None}),

        "plane-only": state(namespaces=[], containers=[]),

        "ready": state(namespaces=[voting_a(READY)], containers=CONTAINERS, objects=OBJECTS),

        "orphaned": state(
            namespaces=[voting_a([
                claim("pgadmin", "Orphaned", "172.19.0.100", [], when(96)),
                claim("postgres", "Orphaned", "172.19.0.102", [], when(96)),
                claim("redis", "Ready", "172.19.0.101", ["worker"])])],
            containers=CONTAINERS, objects=OBJECTS),

        # 45s, not 4: the test asserts the clock moves, and a fixture that has
        # already run out shows 0:00 twice.
        "expiring": state(
            namespaces=[voting_a([claim("postgres", "Orphaned", "172.19.0.102", [], when(45))])],
            containers=CONTAINERS),

        "failed": state(
            namespaces=[voting_a([
                claim("postgres", "Failed", "", []),
                claim("redis", "Ready", "172.19.0.101", ["vote"])])],
            containers=CONTAINERS),

        "pending": state(
            namespaces=[voting_a([claim("postgres", "Pending", "", [])])],
            containers=[]),

        "two-namespaces": state(
            namespaces=[voting_a(READY),
                        {"name": "voting-b", "block": "172.19.0.110-119",
                         "claims": [claim("redis", "Ready", "172.19.0.111", ["vote"])],
                         "ingresses": [route("vote-b.localhost", "voting-app-vote", tls=False)]}],
            containers=CONTAINERS, objects=OBJECTS),

        "no-routes": state(namespaces=[voting_a(READY, routes=False)], containers=CONTAINERS),

        "no-port": state(namespaces=[voting_a(READY)], containers=CONTAINERS,
                         ports={"http": None, "https": None}),
    }

STATE_NAMES = sorted(states())


def write_fixtures():
    FIXTURES.mkdir(exist_ok=True)
    for name, payload in states().items():
        (FIXTURES / f"{name}.json").write_text(json.dumps(payload, indent=2))


def serve_fixture(name):
    """Point serve.py's state command at one fixture file.

    Rewritten on every call, because the fixtures carry timestamps relative to
    now and a suite takes long enough that a countdown written at startup has
    already expired by the time its test opens it.
    """
    write_fixtures()
    serve.STATE = ["cat", str(FIXTURES / f"{name}.json")]


# ------------------------------------------------------------------ server

class Console:
    """The real server, on an ephemeral port, with nothing destructive allowed."""

    def __enter__(self):
        write_fixtures()
        self.real_allowed = serve.ALLOWED
        self.real_state = serve.STATE
        self.real_claim = serve.CLAIM
        self.real_timeline = getattr(serve, "TIMELINE", None)
        serve.ALLOWED = {name: ["python3", "-c", f"print('ran {name}')"]
                         for name in self.real_allowed}
        serve.CLAIM = ["python3", "-c",
                       "print('kind: InfraClaim'); print('  finalizers: [ jit.infra/destroy ]')"]
        if self.real_timeline is not None:
            serve.TIMELINE = ["python3", "-c",
                              """print('{"up": true, "t0": null, "events": []}')"""]
        serve_fixture("ready")
        self.server = serve.build_server(0)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        serve.ALLOWED = self.real_allowed
        serve.STATE = self.real_state
        serve.CLAIM = self.real_claim
        if self.real_timeline is not None:
            serve.TIMELINE = self.real_timeline


# ------------------------------------------------------------------- tests

class Page(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.console = Console().__enter__()
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch()

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()
        cls.console.__exit__()

    def open(self, fixture, tab=None, mode=None):
        serve_fixture(fixture)
        page = self.browser.new_page(viewport={"width": 1440, "height": 900})
        page.goto(self.console.base, wait_until="networkidle")
        if mode:
            page.click(f'#modeSwitch button[data-mode="{mode}"]')
        if tab:
            page.click(f'.seg.mid button[data-view="{tab}"]')
        page.wait_for_timeout(250)
        self.addCleanup(page.close)
        return page

    # -------------------------------------------------- nothing running

    def test_with_no_cluster_the_status_says_so(self):
        page = self.open("down")
        self.assertEqual(page.inner_text("#ledText"), "Nothing running")
        self.assertIn("Nothing is running", page.inner_text("#setupH1"))

    def test_with_no_cluster_both_other_tabs_offer_a_way_out(self):
        for tab, empty in (("infra", "#infraEmpty"), ("app", "#appEmpty")):
            page = self.open("down", tab=tab)
            self.assertTrue(page.is_visible(empty), f"{tab} has no empty state")
            self.assertTrue(page.is_visible(f"{empty} .btn"), f"{tab} offers no button")

    def test_the_plane_without_an_app_is_not_reported_as_empty(self):
        page = self.open("plane-only")
        self.assertEqual(page.inner_text("#ledText"), "No claims")

    # -------------------------------------------------------- claim cards

    def test_every_claim_becomes_a_card(self):
        page = self.open("ready", tab="infra")
        self.assertEqual(page.locator(".claim").count(), 3)
        self.assertEqual(page.inner_text("#ledText"), "3 claims Ready")

    def test_a_card_says_who_is_using_it(self):
        page = self.open("ready", tab="infra")
        text = page.inner_text("#nsHost")
        self.assertIn("vote", text)
        self.assertIn("worker", text)

    def test_the_namespace_summary_shows_the_block(self):
        page = self.open("ready", tab="infra")
        self.assertIn("172.19.0.100-109", page.inner_text("#nsSummary"))

    def test_two_namespaces_are_both_listed(self):
        page = self.open("two-namespaces", tab="infra")
        summary = page.inner_text("#nsSummary")
        self.assertIn("voting-a", summary)
        self.assertIn("voting-b", summary)
        self.assertEqual(page.locator(".claim").count(), 4)

    # ------------------------------------------------------- the countdown

    def test_an_orphaned_claim_shows_a_clock(self):
        page = self.open("orphaned", tab="infra")
        self.assertEqual(page.inner_text("#ledText"), "2 on the clock")
        self.assertGreater(page.locator("[data-expires]").count(), 0)

    def test_the_clock_actually_ticks(self):
        page = self.open("expiring", tab="infra")
        first = page.inner_text("[data-expires]")
        page.wait_for_timeout(1400)
        second = page.inner_text("[data-expires]")
        self.assertNotEqual(first, second, f"the countdown did not move ({first})")

    def test_redis_stays_ready_while_the_others_count_down(self):
        page = self.open("orphaned", tab="infra")
        text = page.inner_text("#nsHost")
        self.assertIn("In use", text)
        self.assertIn("On the clock", text)

    def test_a_failed_claim_is_visible_as_failed(self):
        page = self.open("failed", tab="infra")
        self.assertIn("failed", page.inner_text("#ledText").lower())

    # ------------------------------------------------------- the app panes

    def test_the_panes_use_the_ingress_host_and_port(self):
        """The host and port come from the fixture's Ingress, not from a guess."""
        page = self.open("ready", tab="app")
        self.assertIn("vote.localhost:8082", page.inner_text("#voteUrl"))
        self.assertIn("result.localhost:8082", page.inner_text("#resultUrl"))
        self.assertEqual(page.get_attribute("#voteOpen", "href"),
                         "https://vote.localhost:8082")

    def test_an_http_route_does_not_become_https(self):
        """tls decides the scheme, so a plain route must open on the http port."""
        page = self.open("two-namespaces", tab="app")
        page.click('#nsSwitch button[data-ns="1"]') if page.locator(
            '#nsSwitch button[data-ns="1"]').count() else page.locator(
            "#nsSwitch button").nth(1).click()
        page.wait_for_timeout(250)
        self.assertEqual(page.get_attribute("#voteOpen", "href"),
                         "http://vote-b.localhost:8081")

    def test_a_namespace_with_no_routes_says_so_instead_of_guessing(self):
        page = self.open("no-routes", tab="app")
        self.assertIn("no Ingress", page.inner_text("#voteUrl"))

    def test_the_namespace_switcher_appears_only_with_two(self):
        one = self.open("ready", tab="app")
        self.assertFalse(one.is_visible("#nsSwitch"))
        two = self.open("two-namespaces", tab="app")
        self.assertTrue(two.is_visible("#nsSwitch"))

    # ------------------------------------------------------------- actions

    def test_demo_and_testing_offer_different_rows(self):
        demo = self.open("ready", mode="demo")
        test = self.open("ready", mode="test")
        self.assertNotEqual(demo.inner_text("#actionList"), test.inner_text("#actionList"))
        self.assertIn("Start the demo", demo.inner_text("#actionList"))
        self.assertIn("Check the JIT behaviour", test.inner_text("#actionList"))

    def test_every_row_that_destroys_asks_first(self):
        page = self.open("ready", mode="test")
        page.on("dialog", lambda d: d.dismiss())
        rows = page.locator(".item")
        for i in range(rows.count()):
            if "Delete everything" in rows.nth(i).inner_text():
                rows.nth(i).click()
                page.wait_for_timeout(300)
                self.assertNotIn("ran destroy", page.inner_text("#log"),
                                 "a dismissed confirm still ran the command")
                return
        self.fail("no destructive row found in Testing")

    def test_a_run_streams_into_the_log(self):
        page = self.open("ready", mode="demo")
        page.locator(".item").first.click()
        page.wait_for_selector("#log:has-text('ran demo-up')", timeout=8000)
        self.assertIn("exit 0", page.inner_text("#log"))

    # -------------------------------------------------------- claim object

    def test_clicking_a_card_shows_the_object(self):
        page = self.open("ready", tab="infra")
        page.locator(".claim").first.click()
        page.wait_for_selector("#objectPanel .yaml", timeout=5000)
        self.assertIn("InfraClaim", page.inner_text("#objectPanel"))
        self.assertIn("finalizers", page.inner_text("#objectPanel"))

    # --------------------------------------------------------------- tabs

    def test_exactly_one_view_is_visible_at_a_time(self):
        page = self.open("ready")
        for tab in ("setup", "infra", "app", "guide"):
            page.click(f'.seg.mid button[data-view="{tab}"]')
            page.wait_for_timeout(120)
            self.assertEqual(page.locator(".view.on").count(), 1)
            self.assertTrue(page.is_visible(f"#view-{tab}"))

    def test_the_guide_lists_every_action(self):
        page = self.open("ready", tab="guide")
        listed = page.inner_text("#guideActions")
        for label in ("Start the demo", "Delete everything", "Check the app works"):
            self.assertIn(label, listed)

    # ------------------------------------------------------------ console

    def test_no_javascript_errors_anywhere(self):
        for fixture in STATE_NAMES:
            serve_fixture(fixture)
            page = self.browser.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(self.console.base, wait_until="networkidle")
            for tab in ("infra", "app", "guide", "setup"):
                page.click(f'.seg.mid button[data-view="{tab}"]')
                page.wait_for_timeout(120)
            page.close()
            self.assertEqual(errors, [], f"{fixture} raised: {errors}")


# ----------------------------------------------------------------- shots

def screenshots():
    """One PNG per state, so ten permutations can be reviewed by eye at once."""
    SHOTS.mkdir(exist_ok=True)
    with Console() as console, sync_playwright() as pw:
        browser = pw.chromium.launch()
        for fixture in STATE_NAMES:
            serve_fixture(fixture)
            for tab in ("setup", "infra", "app"):
                page = browser.new_page(viewport={"width": 1440, "height": 950})
                page.goto(console.base, wait_until="networkidle")
                page.click(f'.seg.mid button[data-view="{tab}"]')
                page.wait_for_timeout(700)
                out = SHOTS / f"{fixture}-{tab}.png"
                page.screenshot(path=str(out), full_page=True)
                page.close()
                print(out.name)
        browser.close()
    print(f"\n{len(list(SHOTS.glob('*.png')))} shots in {SHOTS}")


if __name__ == "__main__":
    if "--shots" in sys.argv:
        screenshots()
    else:
        unittest.main(verbosity=2)
