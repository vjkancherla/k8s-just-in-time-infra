Updated: 2026-10-09

## Working
S16: `make verify` = 17 PASS, 0 FAIL against out-of-cluster infra; checkpoint exit 0 on three
runs. The app in `default` consumes JIT-provisioned Redis/Postgres/pgAdmin containers.

## Done (verified)
- S0-S13: checkpoints pass, committed
- S14: real provisioning via the runner; review CLEAR, one item UNVERIFIED
- S15: exit 0 on three runs; 3 containers; vote -> result; tally 0 -> 1; review CONCERNS, all
  four addressed (52170d3)
- S16: exit 0 on three runs; R2/R8/R9/R10/R11/R16/R17 reworked, plus R3/R4/R6/R7 via the
  `psql_q`/`redis_q` helpers

## In progress
- none — awaiting the S16 review (human-run, different model)

## Blocked
- none

## Learnings
- "Rework the six checks the migration invalidates" was an incomplete inventory: R3/R4/R6/R7
  broke through the shared `psql_q`/`redis_q` helpers, and R7 called `kubectl exec "$PGPOD"`
  itself. Grep for the helper, not the requirement number.
- A stale gate's green can be latency, not health: S00.sh passed only while the pre-migration
  app happened to still be running in `default`.
- `int(outputs.get("port", "6379"))` gives `jit-pgadmin` redis's port, because the pgadmin
  module exposes no `port` output.
- kustomize rejects an overlay whose `resources:` reaches a directory containing the overlay
  itself; use a sibling subtree (base/ + overlays/ with `resources: ../../base`)
- R12 seds the registry hostname into the base instead of building the overlay, so a broken
  overlay still passes `make verify`; only `kubectl kustomize <overlay>` catches it
- `tofu output` in plain text renders sensitive values as "<sensitive>" — never route a secret
  through a module output while the runner parses plain text
- Failed is terminal until the Deployment changes; leave a claim pending when a dependency is
  not ready
- Heredocs are flaky in this tool shell; write the payload to a /tmp file instead
