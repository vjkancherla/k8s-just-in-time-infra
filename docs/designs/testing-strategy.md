# Testing Strategy

## Overview

The PoC uses two verification suites — one for the voting app and one for the JIT
lifecycle. Both are shell scripts that write results to markdown files and exit non-zero
on any failure.

| Suite | Script | Output | Checks |
|---|---|---|---|
| App verification | `app/scripts/verify.sh` | `app/.workflow/verify.md` | R1–R17 |
| JIT lifecycle | `scripts/verify-jit.sh` | `.workflow/verify-jit.md` | J1–J11 |

Run both via make:

```bash
make verify          # R1-R17 (default: NS=voting-a)
make jit-verify      # J1-J11
```

## R1–R17: App Verification

These checks verify the voting app works correctly inside a JIT-provisioned namespace.
They are the same checks the original voting app uses, adapted for the JIT context.

| # | What it checks |
|---|---|
| R1 | Vote page is reachable |
| R2 | Result page is reachable |
| R3 | Vote → Redis → Worker → Postgres pipeline works end-to-end |
| R4 | Voting produces a visible tally on the result page |
| R5–R7 | Services, EndpointSlices, and pods exist and are healthy |
| R8–R9 | Redis and Postgres containers are running with correct IPs |
| R10 | pgAdmin is reachable and the Postgres server is registered |
| R11–R12 | Secrets exist and contain expected keys |
| R13 | HTTPS ingress works (self-signed) |
| R14–R16 | Additional ingress and connectivity checks |
| R17 | All resources are in the expected namespace |

The exact checks are in `app/scripts/verify.sh`. To run against a specific namespace:

```bash
make verify NS=voting-b
```

## J1–J11: JIT Lifecycle Verification

These checks verify the JIT infrastructure controller's behaviour — provisioning,
orphaning, resurrection, hard delete, and failure modes.

| # | What it checks | Category |
|---|---|---|
| J1 | Deploy → three claims `Ready`, three containers with correct IPs | Provisioning |
| J2 | Secrets, Services, EndpointSlices exist; R1-R17 pass | Integration |
| J3 | pgAdmin reachable, Postgres server registration works | Module correctness |
| J4 | Delete Deployment → claims `Orphaned` with `expiresAt`; containers still running | Soft delete |
| J5 | Redeploy within window → claims `Ready`, same containers, tally intact | Resurrection |
| J6 | Delete Deployment, wait past TTL → containers destroyed, Secrets/Services removed | TTL sweep |
| J7 | Two Deployments reference redis; delete one → claim stays `Ready` | Refcount rule |
| J8 | `kubectl delete ns voting-b` → its containers destroyed immediately, `voting-a` untouched | Hard delete |
| J9 | Kill controller, delete Deployment, restart → resync marks it `Orphaned` | Resilience |
| J10 | Stop runner, deploy → claims `Failed` with readable message | Failure mode |
| J11 | MinIO shows one state object per namespace-module | State management |

J4/J5 are the soft path. J8 is the hard path. J7 is the refcount rule. J9 is the one
most designs skip.

## Frozen Checkpoints (S00–S18)

The `scripts/checks/` directory contains 19 frozen checkpoint scripts (S00.sh through
S18.sh). These are the build plan's acceptance tests — each one was written at a specific
step and must continue to pass:

```bash
make check STEP=15   # Run checkpoint S15
```

Checkpoints are **frozen**: they are not updated when the code changes. A checkpoint that
starts failing after a later change is a design question, not a checkpoint edit. This
ensures the project's acceptance criteria don't silently drift.

Evidence from each run goes to `docs/evidence/<target>.log`.

## Adding a New Check

To add a check to the JIT lifecycle suite:

1. Edit `scripts/verify-jit.sh`
2. Add a check function following the existing pattern (e.g., `cond "description" test`)
3. The check should print a PASS/FAIL line and contribute to the summary count
4. Update the J-count in the summary and document the new check in this file

To add a check to the app verification suite:

1. Edit `app/scripts/verify.sh`
2. Follow the existing R-check pattern

## Running Tests

```bash
# Full cold start and verification
make demo-up          # Creates cluster, deploys app, verifies R1-R17

# Just the JIT lifecycle
make jit-verify       # Runs J1-J11

# App verification only
make verify NS=voting-a

# A specific checkpoint
make check STEP=17

# Console tests (Python unit tests for serve.py)
cd console && python3 -m pytest test_serve.py -v

# Controller IPAM tests
cd jit-controller && python3 -m pytest test_ipam.py -v
```

## What the checks do not cover

The verification suites are intentionally scoped to the PoC's limits. They do not test:

- **Concurrent provisioning** — only one namespace is provisioned at a time in J1-J11
- **Network isolation** — all containers share one Docker bridge
- **Authentication/authorization** — the runner has no auth in test mode
- **Backup/restore** — not implemented in the PoC
- **Long-running stability** — checks run once, not continuously

For production, these would become separate test suites with appropriate tooling.