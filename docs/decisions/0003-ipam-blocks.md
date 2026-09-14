# 0003. IPAM: per-namespace blocks of 10 from 172.19.0.100-199

Date: 2026-09-01
Status: accepted

## Context

Docker containers on the k3d bridge network need predictable IPs so that the controller
can write Service/EndpointSlice pairs that point at them. The k3d network uses
`172.19.0.0/16`; addresses below `.100` are used by k3d nodes, the runner (`.10`), and
MinIO (`.11`).

The PoC supports up to 10 namespaces, each needing up to 10 addresses (one per module
instance — currently 3: redis, postgres, pgadmin).

## Decision

`jit-controller/ipam.py` allocates blocks of 10 from the range `172.19.0.100-199`:

| Constant | Value | Meaning |
|---|---|---|
| `IP_RANGE_START` | 100 | First usable octet |
| `IP_RANGE_END` | 199 | Last usable octet |
| `BLOCK_SIZE` | 10 | Addresses per namespace |

State is a `jit-ipam` ConfigMap in `default` namespace, storing a JSON map of
`namespace → {offset, base_ip, count}`. `count` tracks how many claims hold an address
from the block; when it hits 0 the block is freed.

Each claim gets its own address from within the block via `first_free_address()` — two
claims in the same namespace never share an IP (this was a bug found during S14).

## Consequences

- **Easy**: Simple to reason about. No external IPAM dependency. The ConfigMap is readable
  with `kubectl` and the console can display blocks.
- **Hard**: Hard-capped at 10 namespaces. Extending requires changing `IP_RANGE_END` and
  ensuring the k3d network has the space. The `172.19.0.x` prefix is tied to the k3d
  bridge network — a different Docker network or a non-Docker runtime would need different
  addresses.
- **Ruled out**: Dynamic DHCP (too much infrastructure for a PoC). Single IP per namespace
  (insufficient — redis, postgres, and pgadmin each need their own). Host networking.

See [`jit-controller/ipam.py`](../../jit-controller/ipam.py) for the implementation.