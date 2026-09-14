# 0004. Console: stateless page behind a make-target allowlist

Date: 2026-09-12
Status: accepted

## Context

The PoC needs a way to drive the full lifecycle (cold start → verify → teardown) without
memorising make targets. The console serves this role, but it must not become a second
source of truth or a security risk.

## Decision

The console (`console/serve.py`) is a local-only HTTP server that:

1. **Holds no state** — everything displayed comes from `make state`, which reads kubectl,
   the IPAM ledger, Docker, and MinIO. If the page computed a phase or expiry for itself,
   it would eventually disagree with `make jit-verify`.
2. **Runs only an allowlist** — every action is one entry in `serve.py`'s `ALLOWED` dict,
   which maps button names to `make` invocations. A name missing from `ALLOWED` returns a
   404, not an arbitrary command. The full list is:

   | Button name | Make target | Mode |
   |---|---|---|
   | `demo-up` | `make demo-up` | Demo |
   | `demo-undeploy` | `make demo-undeploy` | Demo |
   | `demo-redeploy` | `make demo-redeploy` | Demo |
   | `ns-delete-a` | `make ns-delete NS=voting-a` | Demo |
   | `test-up` | `make test-up` | Testing |
   | `jit-up` | `make jit-up` | Testing |
   | `verify` | `make verify NS=voting-a` | Testing |
   | `jit-verify` | `make jit-verify` | Testing |
   | `ns-delete-b` | `make ns-delete NS=voting-b` | Testing |
   | `jit-down` | `make jit-down` | Testing |
   | `destroy` | `make destroy` | Both |

3. **Binds `127.0.0.1`** — no auth, no TLS, no network exposure. The `ALLOWED` dict is the
   security boundary.

The console has two modes:
- **Demo** — one namespace (`voting-a`), guided walkthrough with 4 buttons
- **Testing** — both namespaces, full lifecycle with 7 buttons

Adding an action requires changes in three places that must agree on the name:
`CONSOLE_TARGETS` in the Makefile, `ALLOWED` in `serve.py`, and `ACTIONS` in
`index.html`.

## Consequences

- **Easy**: The page cannot drift from `make verify` — both read the same data. No
  database, no session state, no auth to manage. New buttons are added in three places.
- **Hard**: The page cannot be served from the cluster (it runs `make` locally). Long
  runs block on a threading lock (one at a time). Log pane is lost on server restart.
- **Ruled out**: A stateful web app. Arbitrary command execution. Running in-cluster.

See [`console/README.md`](../../console/README.md) for the full reference.