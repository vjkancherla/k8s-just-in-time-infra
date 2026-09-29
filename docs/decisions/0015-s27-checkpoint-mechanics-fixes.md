# 0015. S27 checkpoint mechanics fixes (harness reaches a correct module)

Date: 2026-09-29
Status: accepted

## Context

`scripts/checks/S27.sh` was frozen in the S22 pre-flight (commit `d0d4329`) and has never
run green — the all-fail capture stops at its precondition (`docs/evidence/s22-all-fail.log`
line 16, "runner not up"). With the runner up, four harness defects stop a *correct*
implementation from satisfying it. None of them is an assertion about the module:

1. **The runner URL is not host-reachable.** The script drives `172.19.0.10:8080`
   (`S27.sh:16` before this ADR). That is the runner's address *on the k3d Docker network*;
   from the host the runner answers only on its published port, `127.0.0.1:8100`
   (`deploy/runner.sh` runs `-p 8100:8080`). Measured on this host:
   `curl http://172.19.0.10:8080/health` → `000`; `curl http://127.0.0.1:8100/health`
   → `200`. The sibling frozen gate `S24.sh:14` already uses the published port.
2. **The POST has no `Content-Type`.** `post()` sends `curl -d` without a JSON content
   type, so curl form-encodes the body and FastAPI answers the Pydantic model with
   `422`. This is the exact defect recorded for S24 in
   [ADR 0008](0008-s24-checkpoint-setup-fixes.md); `S24.sh:16` carries the header.
3. **The container and volume names drop the module suffix.** The script names the POST's
   `name` `$WS-pg` but then greps for a container `$WS-pg` and a volume `$WS-pg-data`
   (`S27.sh:25,30,63,69,74-75`). The postgres module names them `${var.name}-postgres`
   and `${var.name}-postgres-data` (`jit-modules/modules/postgres/main.tf:29,22`;
   `docs/designs/runner-api.md:154`); every live container is e.g.
   `voting-a-postgres-postgres`, and the sibling gate greps exactly that
   (`S24.sh:97,110`, `$PGWS-postgres`). As frozen, step 1's container grep can never match
   a conforming module, step 4's container grep can never match, and step 4's volume grep
   `$WS-pg-data` matches nothing at all — so it asserted the volume *survived* by
   accident while reporting nothing.
4. **The destroy status string is wrong.** Step 4 greps the `DELETE` response for
   `success` (`S27.sh:71`), but the runner returns `{"status":"destroyed"}`
   (`docs/designs/runner-api.md:127`); `S24.sh:103` accepts `success|destroyed`.

The assertion set itself is sound: it drives the runner independently, adds a database and
requires the container id to be unchanged, replaces the server on a settings change and
requires the named volume and its rows to survive, and requires the destroy to remove
container and volume after the runner's `state rm` of `postgresql_*`.

## Decision

Amend `scripts/checks/S27.sh` for those four mechanics only:

- `RUNNER=127.0.0.1:8100` (the published host port).
- `post()` adds `-H "Content-Type: application/json"`.
- The live object is `PG="$WS-pg-postgres"`; every `docker ps`/`docker exec`/`docker
  inspect`/`docker rm` reference and the volume grep use the module's naming
  (`$WS-pg-postgres`, `$WS-pg-postgres-data`).
- The destroy check accepts `success|destroyed`.

No assertion is deleted, weakened, or re-shaped. Fixing the volume pattern makes an
assertion that was silently vacuous real; fixing the container names makes two assertions
reachable that could otherwise only fail.

## Consequences

**Easy.** A conforming S27 module can now make the frozen contract green, and the volume
survival assertion actually tests the s17 rule ("the volume goes with its container")
instead of matching nothing. The harness now follows the same host convention as S24.

**Hard / ruled out.** The checkpoint edits are committed with this ADR, as the frozen-
checkpoint rule requires. The service_url assertions are untouched: the module must still
emit `service_url` for the initial database, the runner must still flatten
`service_url_<db>` per database. Nothing about the module's design is decided here.
