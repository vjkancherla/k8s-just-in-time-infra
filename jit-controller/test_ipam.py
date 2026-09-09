"""Unit tests for jit-controller/ipam.py — pure IPAM logic.

Run with: python3 -m pytest jit-controller/test_ipam.py -v
"""

import sys
from unittest.mock import MagicMock

# Mock the kubernetes module before importing ipam (it's only used by the
# ConfigMap functions, not the pure IP arithmetic we're testing here).
sys.modules.setdefault("kubernetes", MagicMock())
sys.modules.setdefault("kubernetes.client", MagicMock())

import pytest

from ipam import (
    BLOCK_SIZE,
    IP_RANGE_END,
    IP_RANGE_START,
    _base_ip,
    _free_offsets,
)


# ── _base_ip ──────────────────────────────────────────────────────────────────


class TestBaseIP:
    def test_first_block(self):
        assert _base_ip(0) == "172.19.0.100"

    def test_second_block(self):
        assert _base_ip(1) == "172.19.0.110"

    def test_last_block(self):
        total = (IP_RANGE_END - IP_RANGE_START + 1) // BLOCK_SIZE  # 10
        assert _base_ip(total - 1) == "172.19.0.190"

    def test_all_blocks_in_range(self):
        total = (IP_RANGE_END - IP_RANGE_START + 1) // BLOCK_SIZE
        for i in range(total):
            ip = _base_ip(i)
            octet = int(ip.rsplit(".", 1)[1])
            assert IP_RANGE_START <= octet <= IP_RANGE_END - BLOCK_SIZE + 1

    def test_blocks_are_ten_apart(self):
        total = (IP_RANGE_END - IP_RANGE_START + 1) // BLOCK_SIZE
        for i in range(1, total):
            prev = int(_base_ip(i - 1).rsplit(".", 1)[1])
            curr = int(_base_ip(i).rsplit(".", 1)[1])
            assert curr - prev == BLOCK_SIZE


# ── _free_offsets ─────────────────────────────────────────────────────────────


class TestFreeOffsets:
    def test_all_free_when_empty(self):
        free = _free_offsets({})
        total = (IP_RANGE_END - IP_RANGE_START + 1) // BLOCK_SIZE
        assert len(free) == total
        assert free == list(range(total))

    def test_one_taken(self):
        allocs = {"ns-a": {"offset": 0, "base_ip": "172.19.0.100", "count": 1}}
        free = _free_offsets(allocs)
        assert 0 not in free
        assert len(free) == 9

    def test_several_taken(self):
        allocs = {
            "ns-a": {"offset": 0, "base_ip": "172.19.0.100", "count": 1},
            "ns-b": {"offset": 3, "base_ip": "172.19.0.130", "count": 2},
            "ns-c": {"offset": 9, "base_ip": "172.19.0.190", "count": 1},
        }
        free = _free_offsets(allocs)
        assert 0 not in free
        assert 3 not in free
        assert 9 not in free
        assert len(free) == 7

    def test_all_taken(self):
        allocs = {
            f"ns-{i}": {"offset": i, "base_ip": _base_ip(i), "count": 1}
            for i in range((IP_RANGE_END - IP_RANGE_START + 1) // BLOCK_SIZE)
        }
        free = _free_offsets(allocs)
        assert len(free) == 0
