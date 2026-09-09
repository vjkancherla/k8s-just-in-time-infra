"""IPAM — allocate/release blocks of 10 IPs from 172.19.0.100-199 per namespace.

State lives in a `jit-ipam` ConfigMap in the controller's namespace.
Each namespace that holds at least one InfraClaim owns one /28 block.
"""

import logging

from kubernetes import client

CM_NAME = "jit-ipam"
CM_NAMESPACE = "default"
IP_RANGE_START = 100
IP_RANGE_END = 199
BLOCK_SIZE = 10

logger = logging.getLogger("jit-ipam")


def _base_ip(offset: int) -> str:
    """Return '172.19.0.<octet>' for the given offset into the 100-199 range."""
    return f"172.19.0.{IP_RANGE_START + offset * BLOCK_SIZE}"


def _free_offsets(allocations: dict) -> list:
    """Return list of block-offsets not currently allocated."""
    taken = {v["offset"] for v in allocations.values()}
    total = (IP_RANGE_END - IP_RANGE_START + 1) // BLOCK_SIZE  # 10
    return [i for i in range(total) if i not in taken]


def _read_allocations() -> dict:
    """Read the allocations dict from the jit-ipam ConfigMap.

    Returns empty dict on any error (ConfigMap not found, parse failure, etc.)
    so callers always get a usable value.
    """
    core = client.CoreV1Api()
    try:
        cm = core.read_namespaced_config_map(CM_NAME, CM_NAMESPACE)
        raw = cm.data.get("allocations", "{}")
        allocations = __import__("json").loads(raw)
        if not isinstance(allocations, dict):
            return {}
        return allocations
    except Exception:
        return {}


def _write_allocations(allocations: dict) -> bool:
    """Persist allocations back to the ConfigMap (update or create).

    Returns True on success, False on any error.
    """
    import json

    core = client.CoreV1Api()
    body = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": CM_NAME, "namespace": CM_NAMESPACE},
        "data": {"allocations": json.dumps(allocations)},
    }
    try:
        try:
            core.patch_namespaced_config_map(CM_NAME, CM_NAMESPACE, body)
        except client.exceptions.ApiException as e:
            if e.status == 404:
                core.create_namespaced_config_map(CM_NAMESPACE, body)
            else:
                raise
        return True
    except Exception as e:
        logger.error(f"Failed to write {CM_NAME} ConfigMap: {e}")
        return False


def allocate_block(namespace: str) -> str | None:
    """Allocate an IP block for *namespace*. Returns base IP string or None.

    Idempotent: if the namespace already holds a block, returns the existing
    base IP without incrementing the claim count.
    """
    allocations = _read_allocations()

    # Already allocated — return existing.
    if namespace in allocations:
        return allocations[namespace]["base_ip"]

    free = _free_offsets(allocations)
    if not free:
        logger.error(
            f"No free IP blocks in 172.19.0.{IP_RANGE_START}-{IP_RANGE_END}; "
            f"all {((IP_RANGE_END - IP_RANGE_START + 1) // BLOCK_SIZE)} blocks allocated"
        )
        return None

    offset = free[0]
    base = _base_ip(offset)
    allocations[namespace] = {"offset": offset, "base_ip": base, "count": 1}
    if _write_allocations(allocations):
        logger.info(f"Allocated block {base}/{BLOCK_SIZE} to namespace {namespace}")
        return base
    return None


def release_block(namespace: str) -> None:
    """Decrement claim count for *namespace*; free the block when count hits 0.

    Safe to call for a namespace that has no allocation (no-op).
    """
    allocations = _read_allocations()
    if namespace not in allocations:
        return

    entry = allocations[namespace]
    entry["count"] = max(0, entry.get("count", 1) - 1)
    if entry["count"] == 0:
        del allocations[namespace]
        logger.info(f"Released IP block for namespace {namespace}")
    _write_allocations(allocations)
