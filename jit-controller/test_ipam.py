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
from unittest.mock import patch, call

from ipam import (
    BLOCK_SIZE,
    IP_RANGE_END,
    IP_RANGE_START,
    _base_ip,
    _free_offsets,
    allocate_block,
    release_block,
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


# ── allocate_block / release_block state machine ────────────────────────────


class TestAllocateBlock:
    """Test allocate_block with mocked k8s boundary (_read/_write_allocations)."""

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations", return_value={})
    def test_first_allocate(self, mock_read, mock_write):
        result = allocate_block("ns-a")
        assert result == "172.19.0.100"
        written = mock_write.call_args[0][0]
        assert written["ns-a"]["count"] == 1
        assert written["ns-a"]["offset"] == 0

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations", return_value={
        "ns-a": {"offset": 0, "base_ip": "172.19.0.100", "count": 1},
    })
    def test_idempotent_increments_count(self, mock_read, mock_write):
        """Second allocate for same namespace increments count, doesn't create new block."""
        result = allocate_block("ns-a")
        assert result == "172.19.0.100"
        written = mock_write.call_args[0][0]
        assert written["ns-a"]["count"] == 2

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations", return_value={
        "ns-a": {"offset": 0, "base_ip": "172.19.0.100", "count": 2},
    })
    def test_third_allocate_increments_to_three(self, mock_read, mock_write):
        result = allocate_block("ns-a")
        assert result == "172.19.0.100"
        written = mock_write.call_args[0][0]
        assert written["ns-a"]["count"] == 3

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations")
    def test_two_namespaces_get_different_blocks(self, mock_read, mock_write):
        mock_read.side_effect = [
            {},  # first call: ns-a allocates
            {"ns-a": {"offset": 0, "base_ip": "172.19.0.100", "count": 1}},  # second call: ns-b
        ]
        a = allocate_block("ns-a")
        b = allocate_block("ns-b")
        assert a == "172.19.0.100"
        assert b == "172.19.0.110"

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations")
    def test_all_blocks_exhausted_returns_none(self, mock_read, mock_write):
        allocs = {
            f"ns-{i}": {"offset": i, "base_ip": _base_ip(i), "count": 1}
            for i in range((IP_RANGE_END - IP_RANGE_START + 1) // BLOCK_SIZE)
        }
        mock_read.return_value = allocs
        result = allocate_block("ns-new")
        assert result is None

    @patch("ipam._write_allocations", return_value=False)
    @patch("ipam._read_allocations", return_value={})
    def test_write_failure_returns_none(self, mock_read, mock_write):
        result = allocate_block("ns-a")
        assert result is None


class TestReleaseBlock:
    """Test release_block with mocked k8s boundary."""

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations", return_value={
        "ns-a": {"offset": 0, "base_ip": "172.19.0.100", "count": 1},
    })
    def test_last_release_frees_block(self, mock_read, mock_write):
        release_block("ns-a")
        written = mock_write.call_args[0][0]
        assert "ns-a" not in written  # block freed

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations", return_value={
        "ns-a": {"offset": 0, "base_ip": "172.19.0.100", "count": 2},
    })
    def test_release_decrements_count(self, mock_read, mock_write):
        release_block("ns-a")
        written = mock_write.call_args[0][0]
        assert written["ns-a"]["count"] == 1
        assert "ns-a" in written  # block NOT freed

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations", return_value={})
    def test_release_unknown_namespace_is_noop(self, mock_read, mock_write):
        release_block("ns-ghost")
        mock_write.assert_not_called()


class TestAllocateReleaseLifecycle:
    """End-to-end allocate/release lifecycle with mocked k8s boundary."""

    @patch("ipam._write_allocations", return_value=True)
    @patch("ipam._read_allocations")
    def test_two_claims_one_namespace(self, mock_read, mock_write):
        """Two claims in same namespace: block freed only after second release."""
        # Step 1: first claim allocates
        mock_read.return_value = {}
        allocate_block("ns-x")
        state = mock_write.call_args[0][0]
        assert state["ns-x"]["count"] == 1

        # Step 2: second claim increments
        mock_read.return_value = {"ns-x": {"offset": 0, "base_ip": "172.19.0.100", "count": 1}}
        allocate_block("ns-x")
        state = mock_write.call_args[0][0]
        assert state["ns-x"]["count"] == 2

        # Step 3: first release — block stays
        mock_read.return_value = {"ns-x": {"offset": 0, "base_ip": "172.19.0.100", "count": 2}}
        release_block("ns-x")
        state = mock_write.call_args[0][0]
        assert "ns-x" in state
        assert state["ns-x"]["count"] == 1

        # Step 4: second release — block freed
        mock_read.return_value = {"ns-x": {"offset": 0, "base_ip": "172.19.0.100", "count": 1}}
        release_block("ns-x")
        state = mock_write.call_args[0][0]
        assert "ns-x" not in state
