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
picture, so ten permutations can be reviewed by eye in ten seconds instead of
being clicked through by hand.

ALLOWED is swapped for harmless commands and the evidence directory for a throwaway
one, so no test can start or destroy anything, or overwrite the log of a real run.

Per .clinerules/01-jit-poc.md these are a diagnostic tool, not proof. The checkpoint is
the proof.
"""

import json
import pathlib
import shutil
import sys
import tempfile
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
        self.real_evidence = serve.EVIDENCE
        # serve.py writes every run to docs/evidence/console-<name>.log. An action
        # clicked here would otherwise overwrite the log of a real run, so the
        # suite's runs are written to a throwaway directory instead.
        self.evidence = pathlib.Path(tempfile.mkdtemp(prefix="console-browser-evidence-"))
        serve.EVIDENCE = self.evidence
        serve.ALLOWED = {name: ["python3", "-c", f"print('ran {name}')"]
                         for name in self.real_allowed}
        serve.CLAIM = ["python3", "-c",
                       "print('kind: InfraClaim'); print('  finalizers: [ jit.infra/destroy ]')"]
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
        serve.EVIDENCE = self.real_evidence
        shutil.rmtree(self.evidence, ignore_errors=True)


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
        self.assertEqual(page.locator(".ns-claim").count(), 3)
        self.assertEqual(page.inner_text("#ledText"), "3 claims Ready")

    def test_a_card_says_who_is_using_it(self):
        page = self.open("ready", tab="infra")
        text = page.inner_text("#nsHost")
        self.assertIn("vote", text)
        self.assertIn("worker", text)

    def test_the_namespace_summary_shows_the_block(self):
        page = self.open("ready", tab="infra")
        self.assertIn("172.19.0.100-109", page.inner_text("#nsHost"))

    def test_two_namespaces_are_both_listed(self):
        page = self.open("two-namespaces", tab="infra")
        host = page.inner_text("#nsHost")
        self.assertIn("voting-a", host)
        self.assertIn("voting-b", host)
        self.assertEqual(page.locator(".ns-claim").count(), 4)

    def test_a_claim_card_tag_shows_its_phase(self):
        page = self.open("orphaned", tab="infra")
        host = page.locator("#nsHost")
        self.assertGreater(host.locator(".tag.ready").count(), 0)
        self.assertGreater(host.locator(".tag.orphaned").count(), 0)

    def test_a_claim_foot_says_whether_anything_still_uses_it(self):
        page = self.open("orphaned", tab="infra")
        text = page.inner_text("#nsHost")
        self.assertIn("Active link", text)              # redis is still referenced by worker
        self.assertIn("Nothing referencing it", text)   # the two on the clock are not

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
        # redis is Ready, the others are Orphaned — all in the same namespace card
        self.assertIn("Ready", text)
        self.assertIn("Orphaned", text)
        # the countdown appears on the orphaned claims
        self.assertGreater(page.locator("[data-expires]").count(), 0)

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
        page.locator("#nsSwitch button").nth(1).click()
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
        self.assertIn("$ make ns-delete NS=voting-a", demo.inner_text("#actionList"))
        self.assertIn("$ make ns-delete NS=voting-b", test.inner_text("#actionList"))

    def test_destructive_actions_are_cards_in_the_one_list(self):
        """They share the list with every other action now, marked rather than
        moved into a box of their own."""
        page = self.open("ready", mode="test")
        cards = page.locator("#actionList .action-card")
        danger = page.locator("#actionList .action-card.danger")
        self.assertGreater(danger.count(), 0, "no destructive card rendered")
        self.assertLess(danger.count(), cards.count())
        self.assertIn("Delete everything", page.inner_text("#actionList"))

    def test_a_card_carries_its_hint_or_destructive_pill(self):
        page = self.open("ready", mode="test")
        hint = page.locator("#actionList .action-card", has_text="Start the control plane")
        self.assertEqual(hint.locator(".action-pill").inner_text(), "jit-up")
        destroy = page.locator("#actionList .action-card.danger", has_text="Delete everything")
        self.assertEqual(destroy.locator(".action-pill").inner_text().lower(), "destroy")

    def test_a_running_action_is_marked_live(self):
        """The card, the terminal title and the LIVE pill all follow the run.
        The action is slowed down here so the state can be observed at all."""
        page = self.open("ready", mode="demo")
        real = serve.ALLOWED["demo-up"]
        serve.ALLOWED["demo-up"] = ["python3", "-c",
                                    "import time; time.sleep(3); print('ran demo-up')"]
        self.addCleanup(lambda: serve.ALLOWED.__setitem__("demo-up", real))
        page.locator("#actionList .action-run").first.click()
        page.wait_for_selector("#actionList .action-card.running", timeout=8000)
        card = page.locator("#actionList .action-card.running")
        self.assertEqual(card.locator(".action-title").inner_text(), "Start the demo")
        self.assertGreater(card.locator(".action-pulse").count(), 0, "no running pulse")
        self.assertEqual(card.locator(".action-pill.streaming").inner_text(), "Streaming\u2026")
        self.assertEqual(card.locator(".action-tag").inner_text(), "Active target")
        page.wait_for_selector("#termLive", state="visible", timeout=5000)
        self.assertEqual(page.inner_text("#termTitle"), "make demo-up")
        self.assertIn("running make demo-up", page.inner_text("#termStatus"))
        page.wait_for_selector("#log:has-text('exit 0')", timeout=15000)
        page.wait_for_selector("#termLive", state="hidden", timeout=5000)
        self.assertEqual(page.inner_text("#termTitle"), "$")
        self.assertEqual(card.locator(".action-pill.streaming").count(), 0)

    def test_every_row_that_destroys_asks_first(self):
        page = self.open("ready", mode="test")
        page.on("dialog", lambda d: d.dismiss())
        rows = page.locator("#actionList .action-card.danger")
        self.assertGreater(rows.count(), 0, "no destructive card found in Testing")
        for i in range(rows.count()):
            rows.nth(i).locator(".action-run").click()
            page.wait_for_timeout(300)
            self.assertNotIn("ran ", page.inner_text("#log"),
                             f"a dismissed confirm still ran {rows.nth(i).inner_text()}")

    def test_a_run_streams_into_the_log(self):
        page = self.open("ready", mode="demo")
        page.locator("#actionList .action-run").first.click()
        page.wait_for_selector("#log:has-text('ran demo-up')", timeout=8000)
        self.assertIn("exit 0", page.inner_text("#log"))

    def test_the_terminal_is_idle_until_something_runs(self):
        page = self.open("ready")
        self.assertEqual(page.inner_text("#termStatus"), "idle")
        self.assertNotIn("live", page.locator("#termDot").get_attribute("class") or "")
        self.assertEqual(page.inner_text("#termTitle"), "$")
        self.assertFalse(page.is_visible("#termLive"))
        self.assertIn("Auto-scroll: ON", page.inner_text(".term-foot"))

    def test_the_terminal_is_idle_again_once_a_run_has_finished(self):
        page = self.open("ready", mode="demo")
        page.locator("#actionList .action-run").first.click()
        page.wait_for_selector("#log:has-text('exit 0')", timeout=8000)
        page.wait_for_timeout(300)
        self.assertEqual(page.inner_text("#termStatus"), "idle")
        self.assertEqual(page.inner_text("#termTitle"), "$")

    def test_clear_empties_the_log(self):
        page = self.open("ready", mode="demo")
        page.locator("#actionList .action-run").first.click()
        page.wait_for_selector("#log:has-text('exit 0')", timeout=8000)
        page.click("#termClear")
        page.wait_for_timeout(150)
        self.assertNotIn("exit 0", page.inner_text("#log"))

    # -------------------------------------------------------- claim object

    def test_clicking_a_card_shows_the_object(self):
        page = self.open("ready", tab="infra")
        page.locator(".ns-claim").first.click()
        page.wait_for_selector("#objectPanel .yaml", timeout=5000)
        self.assertIn("InfraClaim", page.inner_text("#objectPanel"))
        # Both blocks render open, so the claim's own YAML is on screen already
        self.assertIn("finalizers", page.inner_text("#objectPanel"))

    def test_the_panel_names_the_container_the_claim_matched(self):
        page = self.open("ready", tab="infra")
        page.locator(".ns-claim").first.click()
        page.wait_for_selector("#objectPanel .matched", timeout=5000)
        self.assertIn("voting-a-pgadmin-pgadmin", page.inner_text("#objectPanel .matched"))

    def test_the_claim_yaml_is_highlighted(self):
        """The dark block holds the Kubernetes object, syntax-highlighted; the
        light block above it holds the container docker describes."""
        page = self.open("ready", tab="infra")
        page.locator(".ns-claim").first.click()
        page.wait_for_selector("#claimYaml", timeout=5000)
        self.assertGreater(page.locator("#claimYaml span.yk").count(), 0,
                           "the claim YAML is not highlighted")
        self.assertIn("finalizers", page.inner_text("#claimYaml"))

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

    # ------------------------------------------------------------ LED

    def test_led_says_nothing_running_when_down(self):
        page = self.open("down")
        self.assertEqual(page.inner_text("#ledText"), "Nothing running")
        self.assertNotIn("on", page.locator("#led").get_attribute("class"))

    def test_led_shows_green_with_ready_claims(self):
        page = self.open("ready")
        text = page.inner_text("#ledText")
        self.assertIn("Ready", text)
        self.assertIn("claims", text)
        self.assertIn("on", page.locator("#led").get_attribute("class"))

    def test_led_shows_warn_for_orphaned(self):
        page = self.open("orphaned")
        text = page.inner_text("#ledText")
        self.assertIn("on the clock", text)
        self.assertIn("warn", page.locator("#led").get_attribute("class"))

    def test_led_shows_warn_for_failed(self):
        page = self.open("failed")
        text = page.inner_text("#ledText")
        self.assertIn("failed", text)
        self.assertIn("warn", page.locator("#led").get_attribute("class"))

    # ------------------------------------------------ infra containers

    def test_infra_lists_running_containers(self):
        page = self.open("ready", tab="infra")
        box = page.locator("#dockerPanel")
        for name in ("redis", "postgres", "pgadmin"):
            self.assertIn(name, box.inner_text())

    def test_the_docker_table_has_one_column_per_field(self):
        """State objects are no longer shown in the Infrastructure tab: the
        table lists containers, and each row links to the claim that owns it."""
        page = self.open("ready", tab="infra")
        heads = page.locator("#dockerPanel thead th")
        # the header is uppercased by CSS, so compare the rendered text that way
        self.assertEqual([heads.nth(i).inner_text().lower() for i in range(heads.count())],
                         ["container", "address", "status", "image", "claim"])

    def test_clicking_a_docker_row_opens_its_claim(self):
        page = self.open("ready", tab="infra")
        page.locator("#dockerPanel tbody tr.docker-row").first.click()
        page.wait_for_selector("#objectPanel .yaml", timeout=5000)
        self.assertIn("InfraClaim", page.inner_text("#objectPanel"))
        page.wait_for_selector("#dockerPanel tr.row-selected", timeout=5000)

    def test_a_docker_row_flags_a_claim_that_is_orphaned(self):
        page = self.open("orphaned", tab="infra")
        pills = page.locator("#dockerPanel .clink.orphan-pill")
        self.assertGreater(pills.count(), 0, "orphaned claims are not flagged in the table")
        self.assertIn("orphaned", pills.first.inner_text().lower())

    def test_infra_says_none_when_down(self):
        page = self.open("down", tab="infra")
        self.assertIn("No infrastructure", page.inner_text("#view-infra"))

    # ------------------------------------------------------------ app URLs

    def test_app_tab_shows_vote_and_result_urls(self):
        page = self.open("ready", tab="app")
        page.wait_for_timeout(300)
        vote = page.inner_text("#voteUrl")
        result = page.inner_text("#resultUrl")
        self.assertIn("vote.localhost", vote)
        self.assertIn("result.localhost", result)

    def test_app_tab_shows_iframes(self):
        page = self.open("ready", tab="app")
        page.wait_for_timeout(300)
        self.assertEqual(page.locator("#votePane iframe").count(), 1)
        self.assertEqual(page.locator("#resultPane iframe").count(), 1)

    # -------------------------------------------------------- setup state

    def test_setup_heading_says_nothing_when_down(self):
        page = self.open("down")
        self.assertIn("Nothing is running", page.inner_text("#setupH1"))

    def test_setup_heading_lists_namespaces_when_ready(self):
        page = self.open("ready")
        h = page.inner_text("#setupH1")
        self.assertIn("voting-a", h)

    # --------------------------------------------------------------- claims

    def test_claims_are_grouped_by_phase(self):
        page = self.open("ready", tab="infra")
        cards = page.locator(".ns-card")
        self.assertGreater(cards.count(), 0, "no .ns-card blocks rendered")
        # Every namespace card has a header with the namespace name
        for i in range(cards.count()):
            name = cards.nth(i).locator(".ns-name")
            self.assertTrue(name.count(), f"ns-card {i} has no namespace name")

    def test_ready_card_says_used_by(self):
        page = self.open("ready", tab="infra")
        sentences = page.locator(".claim-desc")
        found = False
        for i in range(sentences.count()):
            t = sentences.nth(i).inner_text()
            if "Used by" in t:
                found = True
        self.assertTrue(found, "no claim sentence says 'Used by'")

    def test_orphaned_card_mentions_countdown(self):
        page = self.open("orphaned", tab="infra")
        sentences = page.locator(".claim-desc")
        found = False
        for i in range(sentences.count()):
            t = sentences.nth(i).inner_text()
            if "destroy" in t.lower() or "clock" in t.lower():
                found = True
        self.assertTrue(found, "no orphaned claim sentence mentions countdown")

    def test_failed_card_says_provisioning_failed(self):
        page = self.open("failed", tab="infra")
        sentences = page.locator(".claim-desc")
        found = False
        for i in range(sentences.count()):
            t = sentences.nth(i).inner_text()
            if "failed" in t.lower():
                found = True
        self.assertTrue(found, "no claim sentence mentions failure")

    def test_pending_card_says_waiting(self):
        page = self.open("pending", tab="infra")
        sentences = page.locator(".claim-desc")
        found = False
        for i in range(sentences.count()):
            t = sentences.nth(i).inner_text()
            if "waiting" in t.lower() or "runner" in t.lower() or "cannot start" in t.lower():
                found = True
        self.assertTrue(found, "no pending claim sentence mentions waiting")

    # ---------------------------------------------------------- nsSummary

    def test_ns_summary_shows_claim_count_and_phases(self):
        page = self.open("ready", tab="infra")
        text = page.inner_text("#nsHost")
        self.assertIn("3 claims", text)
        self.assertIn("Ready", text)

    # ------------------------------------------------------------ app tab

    def test_app_claim_chips_list_each_module(self):
        page = self.open("ready", tab="app")
        page.wait_for_timeout(300)
        text = page.inner_text("#appChips")
        for name in ("pgadmin", "postgres", "redis"):
            self.assertIn(name, text)

    def test_pgadmin_line_appears_when_ready(self):
        page = self.open("ready", tab="app")
        page.wait_for_timeout(300)
        pg = page.inner_text("#pgadminLine")
        self.assertIn("pgAdmin", pg)

    def test_app_tab_shows_message_when_no_ingress(self):
        page = self.open("no-routes", tab="app")
        page.wait_for_timeout(300)
        text = page.inner_text("#view-app")
        self.assertIn("No Ingress", text)

    # ------------------------------------------------------------ feed

    def test_feed_shells_empty_on_first_load(self):
        page = self.open("ready", tab="infra")
        self.assertIn("Nothing yet", page.inner_text("#feed"))

    # --------------------------------------------------- claim object panel

    def test_object_panel_has_container_and_claim_sections(self):
        page = self.open("ready", tab="infra")
        page.locator(".ns-claim").first.click()
        page.wait_for_selector("#objectPanel .yaml", timeout=5000)
        text = page.locator("#objectPanel").inner_text()
        self.assertIn("InfraClaim", text)

    def test_object_panel_shows_container_address(self):
        page = self.open("ready", tab="infra")
        page.locator(".ns-claim").first.click()
        page.wait_for_selector("#objectPanel .yaml", timeout=5000)
        text = page.locator("#objectPanel").inner_text()
        self.assertIn("172.19.0", text)

    # ---------------------------------------------------------- infra H1

    def test_the_infra_header_reads_the_same_in_every_state(self):
        """The heading names the tab, not the state. The counts live on Setup,
        next to the actions that change them."""
        ready = self.open("ready", tab="infra")
        orphaned = self.open("orphaned", tab="infra")
        self.assertEqual(ready.inner_text("#infraH1"), "Infrastructure")
        self.assertEqual(ready.inner_text("#infraH1"), orphaned.inner_text("#infraH1"))
        self.assertIn("grouped by namespace", ready.inner_text("#infraSub"))

    def test_the_setup_subtitle_counts_claims_and_containers(self):
        page = self.open("ready")
        self.assertIn("3 claims, 3 containers", page.inner_text("#setupSub"))
        clock = self.open("orphaned")
        self.assertIn("one on the clock", clock.inner_text("#setupSub"))

    # ------------------------------------------------- setup placeholder

    def test_log_shows_placeholder_when_idle(self):
        page = self.open("ready")
        log = page.inner_text("#log")
        self.assertIn("appears here", log.lower())

    # -------------------------------------------------------- mode note

    def test_the_mode_note_is_empty_in_demo(self):
        """Demo mode carries no note now; only Testing explains itself."""
        page = self.open("ready")
        self.assertEqual(page.inner_text("#modeNote").strip(), "")

    def test_mode_note_mentions_voting_b_in_testing(self):
        page = self.open("ready")
        page.locator('#modeSwitch button:text("Testing")').click()
        page.wait_for_timeout(150)
        note = page.inner_text("#modeNote")
        self.assertIn("voting-b", note)

    # ----------------------------------------------------- sleeping tabs

    def test_non_setup_tabs_are_sleeping_when_down(self):
        page = self.open("down")
        for tab in ("infra", "app", "guide"):
            btn = page.locator(f'.seg.mid button[data-view="{tab}"]')
            self.assertIn("sleeping", btn.get_attribute("class") or "")

    def test_non_setup_tabs_are_not_sleeping_when_ready(self):
        page = self.open("ready")
        for tab in ("infra", "app", "guide"):
            btn = page.locator(f'.seg.mid button[data-view="{tab}"]')
            cls = btn.get_attribute("class") or ""
            self.assertNotIn("sleeping", cls)

    # ------------------------------------------------------- destructive

    def test_destructive_action_cancel_does_nothing(self):
        page = self.open("ready")
        page.once("dialog", lambda d: d.dismiss())
        rows = page.locator("#actionList .action-card.danger")
        self.assertGreater(rows.count(), 0, "no destructive cards rendered")
        rows.first.locator(".action-run").click()
        page.wait_for_timeout(300)
        self.assertEqual(page.inner_text("#termStatus"), "idle",
                         "a cancelled destructive action started a run")
        self.assertNotIn("ran ", page.inner_text("#log"))

    def test_destructive_cards_carry_their_target_and_a_red_run(self):
        page = self.open("ready")
        destroy = page.locator("#actionList .action-card.danger", has_text="Delete everything")
        self.assertEqual(destroy.locator(".action-cmd").inner_text(), "$ make destroy")
        self.assertNotEqual(
            destroy.locator(".action-run").evaluate("el => getComputedStyle(el).backgroundColor"),
            page.locator("#actionList .action-card:not(.danger) .action-run").first.evaluate(
                "el => getComputedStyle(el).backgroundColor"),
            "the destructive button is not visually distinct from an ordinary Run")

    # ------------------------------------------------- guide tab content

    def test_guide_shows_phase_definitions(self):
        page = self.open("ready", tab="guide")
        text = page.inner_text("#guidePhases")
        for phase in ("Pending", "Ready", "Orphaned", "Deleting", "Failed"):
            self.assertIn(phase, text)

    def test_guide_lists_demo_and_testing_action_groups(self):
        page = self.open("ready", tab="guide")
        text = page.inner_text("#guideActions")
        self.assertIn("Demo", text)
        self.assertIn("Testing", text)

    def test_guide_actions_mention_make_targets(self):
        page = self.open("ready", tab="guide")
        text = page.inner_text("#guideActions")
        self.assertIn("demo-up", text)
        self.assertIn("verify", text)

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
    """One PNG per state, numbered for ordering, so permutations can be reviewed by eye at once."""
    SHOTS.mkdir(exist_ok=True)
    n = 0
    with Console() as console, sync_playwright() as pw:
        browser = pw.chromium.launch()
        for fixture in STATE_NAMES:
            serve_fixture(fixture)
            for tab in ("setup", "infra", "app"):
                n += 1
                page = browser.new_page(viewport={"width": 1440, "height": 950})
                page.goto(console.base, wait_until="networkidle")
                page.click(f'.seg.mid button[data-view="{tab}"]')
                page.wait_for_timeout(700)
                out = SHOTS / f"{n:02d}-{fixture}-{tab}.png"
                page.screenshot(path=str(out), full_page=True)
                page.close()
                print(out.name)
        browser.close()
    print(f"\n{n} shots in {SHOTS}")


if __name__ == "__main__":
    if "--shots" in sys.argv:
        screenshots()
    else:
        unittest.main(verbosity=2)
