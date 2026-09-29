"""Unit tests for the S26 controller core's pure logic.

Run with: python3 -m unittest test_declarers -v      (stdlib; no pytest needed)

Covers the fiddly pieces the build plan's §Unit tests names, with declarer
resolution added by S26: role resolution from live references, the mutability
contract's validation, and the params hash the retry gate compares.
"""

import sys
import unittest
from unittest.mock import MagicMock

# kopf's decorators run at import; the kubernetes client is only touched by
# reconcile's live calls, which these tests do not make.
sys.modules.setdefault("kubernetes", MagicMock())
sys.modules.setdefault("kubernetes.client", MagicMock())

from main import params_hash, resolve_desired, validate_params


class TestResolveDesired(unittest.TestCase):
    def test_no_references(self):
        desired, declarers, conflict = resolve_desired([])
        self.assertIsNone(desired)
        self.assertEqual(declarers, [])
        self.assertFalse(conflict)

    def test_consumers_only_are_not_declarers(self):
        refs = [("vote", {}, False), ("worker", {}, False)]
        desired, declarers, conflict = resolve_desired(refs)
        self.assertIsNone(desired)
        self.assertEqual(declarers, [])
        self.assertFalse(conflict)

    def test_single_declarer(self):
        refs = [("vote", {"maxmemory": "200mb"}, True),
                ("worker", {}, False)]
        desired, declarers, conflict = resolve_desired(refs)
        self.assertEqual(desired, {"maxmemory": "200mb"})
        self.assertEqual([n for n, _ in declarers], ["vote"])
        self.assertFalse(conflict)

    def test_empty_params_declares_the_defaults(self):
        # params: {} is present, so it declares - unlike a missing params key.
        refs = [("vote", {}, True), ("worker", {}, False)]
        desired, declarers, conflict = resolve_desired(refs)
        self.assertEqual(desired, {})
        self.assertEqual([n for n, _ in declarers], ["vote"])
        self.assertFalse(conflict)

    def test_agreeing_declarers_resolve(self):
        refs = [("a", {"maxmemory": "1gb"}, True),
                ("b", {"maxmemory": "1gb"}, True)]
        desired, declarers, conflict = resolve_desired(refs)
        self.assertEqual(desired, {"maxmemory": "1gb"})
        self.assertEqual(sorted(n for n, _ in declarers), ["a", "b"])
        self.assertFalse(conflict)

    def test_values_are_compared_normalized(self):
        refs = [("a", {"maxmemory": 128}, True),
                ("b", {"maxmemory": "128"}, True)]
        desired, declarers, conflict = resolve_desired(refs)
        self.assertEqual(desired, {"maxmemory": "128"})
        self.assertFalse(conflict)

    def test_disagreeing_declarers_conflict(self):
        refs = [("a", {"maxmemory": "200mb"}, True),
                ("b", {"maxmemory": "999mb"}, True)]
        desired, declarers, conflict = resolve_desired(refs)
        self.assertIsNone(desired)
        self.assertTrue(conflict)
        self.assertEqual(len(declarers), 2)

    def test_consumer_adding_params_follows_the_rules(self):
        # A consumer that adds params becomes a declarer: alone it agrees with
        # itself (rules 5 -> 6, no conflict).
        refs = [("a", {"maxmemory": "200mb"}, True),
                ("b", {}, False)]
        desired, _, conflict = resolve_desired(refs)
        self.assertEqual(desired, {"maxmemory": "200mb"})
        self.assertFalse(conflict)
        # Disagreeing with an existing declarer is a conflict (rule 3).
        refs = [("a", {"maxmemory": "200mb"}, True),
                ("b", {"maxmemory": "300mb"}, True)]
        _, _, conflict = resolve_desired(refs)
        self.assertTrue(conflict)


class TestValidateParams(unittest.TestCase):
    def test_redis_maxmemory_accepts_the_pattern(self):
        for value in ("128mb", "1gb", "512kb"):
            ok, key, _ = validate_params("redis", {"maxmemory": value})
            self.assertTrue(ok, value)

    def test_redis_maxmemory_refuses_banana_and_bare_numbers(self):
        for value in ("banana", "128mib", "128"):
            ok, key, reason = validate_params("redis", {"maxmemory": value})
            self.assertFalse(ok)
            self.assertEqual(key, "maxmemory")
            self.assertTrue(reason)

    def test_unknown_key_is_refused(self):
        ok, key, _ = validate_params("redis", {"wikijunk": "1"})
        self.assertFalse(ok)
        self.assertEqual(key, "wikijunk")

    def test_identity_keys_are_refused(self):
        for key in ("name", "ip", "network", "postgres_db", "postgres_password"):
            ok, bad, _ = validate_params("redis", {key: "x"})
            self.assertFalse(ok, key)
            self.assertEqual(bad, key)

    def test_pgadmin_refuses_every_param_in_v1(self):
        ok, key, _ = validate_params("pgadmin", {"anything": "x"})
        self.assertFalse(ok)
        self.assertEqual(key, "anything")

    def test_postgres_databases_additive_and_identifier_shaped(self):
        ok, _, _ = validate_params("postgres", {"databases": ["voting", "analytics"]})
        self.assertTrue(ok)
        ok, key, _ = validate_params("postgres", {"databases": ["bad name!"]})
        self.assertFalse(ok)
        self.assertEqual(key, "databases")

    def test_postgres_database_removal_is_refused(self):
        ok, key, reason = validate_params(
            "postgres", {"databases": ["voting"]},
            applied={"databases": ["voting", "analytics"]})
        self.assertFalse(ok)
        self.assertEqual(key, "databases")
        self.assertIn("analytics", reason)

    def test_postgres_settings_allowlist_and_types(self):
        ok, _, _ = validate_params(
            "postgres",
            {"settings": {"max_connections": "200", "work_mem": "4MB"}})
        self.assertTrue(ok)
        ok, key, _ = validate_params("postgres", {"settings": {"nonsense": "1"}})
        self.assertFalse(ok)
        self.assertEqual(key, "settings.nonsense")
        ok, key, _ = validate_params(
            "postgres", {"settings": {"max_connections": "many"}})
        self.assertFalse(ok)
        self.assertEqual(key, "settings.max_connections")

    def test_postgres_password_is_never_a_tenant_setting(self):
        ok, key, _ = validate_params("postgres", {"postgres_password": "hunter2"})
        self.assertFalse(ok)
        self.assertEqual(key, "postgres_password")


class TestParamsHash(unittest.TestCase):
    def test_stable_for_the_same_inputs(self):
        self.assertEqual(
            params_hash("redis", "voting-a", {"maxmemory": "128mb"}),
            params_hash("redis", "voting-a", {"maxmemory": "128mb"}))

    def test_changes_with_params_and_workspace(self):
        base = params_hash("redis", "voting-a", {"maxmemory": "128mb"})
        self.assertNotEqual(base, params_hash("redis", "voting-a", {"maxmemory": "256mb"}))
        self.assertNotEqual(base, params_hash("redis", "voting-b", {"maxmemory": "128mb"}))
        self.assertNotEqual(base, params_hash("postgres", "voting-a", {"maxmemory": "128mb"}))

    def test_key_order_does_not_matter(self):
        self.assertEqual(
            params_hash("postgres", "voting-a", {"a": "1", "b": "2"}),
            params_hash("postgres", "voting-a", {"b": "2", "a": "1"}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
