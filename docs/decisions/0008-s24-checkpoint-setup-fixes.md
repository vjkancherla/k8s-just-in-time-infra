# 0008. S24 checkpoint setup fixes: host-reachable runner URL and the redis create's required ip

Date: 2026-09-29
Status: accepted

## Context

`scripts/checks/S24.sh` was written in the S22 pre-flight and frozen at `d0d4329`
(amended once by ADR 0005 for the conditional `state rm` assertions). Running it on
this host for S24 found three setup defects that no correct implementation of S24 can
satisfy. None of them is an assertion; the assertions are sound and unchanged.

1. **The runner URL is not host-reachable.** The checkpoint sets
   `RUNNER=172.19.0.10:8080` and drives it with host `curl`. On this macOS host the
   Docker bridge IP is not routable - `curl --max-time 4 http://172.19.0.10:8080/health`
   times out (exit 28) - while the runner publishes `-p 8100:8080`
   (`deploy/runner.sh:66`) and answers on `127.0.0.1:8100`. The repo's host-side
   callers already use the published port (`scripts/checks/S06.sh:9`,
   `docs/evidence/leak-probe3.sh:84`). S07 uses `172.19.0.10:8080` correctly because it
   drives the runner from inside the cluster; S24 runs on the host.
2. **The redis create omits `ip`.** All three redis POSTs send
   `{name, network, maxmemory}`; `jit-modules/modules/redis/variables.tf` declares
   `ip` with no default, so `tofu apply` fails with "No value for required variable"
   and no container exists for the checkpoint's first assertion. The postgres create
   in the same script passes `ip`, so the omission is an oversight, not a contract.
3. **The postgres create passes `databases` as a list.** The runner's
   `RunRequest.params: Dict[str, str]` rejects a list value with a 422 before any
   apply, and the postgres module does not declare `databases` until S27. The
   checkpoint's positive destroy test needs the create to succeed.
4. **The POSTs send no `Content-Type`.** `curl -d` defaults to
   `application/x-www-form-urlencoded`, so FastAPI answers 422
   (`model_attributes_type`) before the handler runs and no container is ever
   created. The first run of the amended checkpoint died here with an empty log
   (`c=` empty, `fail "no container ..."` never reached because the `grep` under
   `set -e` exited first). The DELETE calls have the same defect: the body is
   ignored, so the destroy falls back to the cached run.

## Decision

Amend `scripts/checks/S24.sh` for the two setup defects that are the checkpoint's own:

- `RUNNER=127.0.0.1:8100` - the published host port, the same address S06 and the
  leak probes use.
- add `"ip":"172.19.0.192"` to the three redis POSTs - the module requires it.
- add `-H "Content-Type: application/json"` to `post()` and to both DELETE calls -
  the API is JSON, and curl's form default is rejected before the handler.

For the third, the implementation adapts rather than the checkpoint: the runner
accepts arbitrary JSON param values (`Dict[str, Any]`, JSON-encoded into `-var`), and
`jit-modules/modules/postgres/variables.tf` declares `databases` (`list(string)`,
default `[]`) so the frozen checkpoint's create succeeds; S27 wires it to
`postgresql_database` resources. No assertion is changed, added or removed.

## Consequences

**Easy.** S24's checkpoint can pass on this host with a correct implementation, and
the runner's param surface matches the design's params (`databases` is a list,
`settings` an object) instead of rejecting them at the API boundary.

**Hard / ruled out.** `scripts/checks/` gains no further edits without a new ADR. The
`databases` variable is declared one step before S27 uses it; S27 must not re-declare
it. The same host-reachability defect exists in `scripts/checks/S27.sh:16` and is
**not** fixed here - S27's step owns it, and this ADR records it so it is not
rediscovered as a surprise.