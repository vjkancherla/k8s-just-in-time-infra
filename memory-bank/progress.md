Updated: 2026-10-09

## Working
S16: `make verify` = 17 PASS, 0 FAIL against out-of-cluster infra; checkpoint exit 0
(/tmp/s16-postfix2.log). `default` runs the migrated app on JIT-provisioned containers.

## Done (verified)
- S0-S13: checkpoints pass, committed
- S14: real provisioning via the runner; review CLEAR, one item UNVERIFIED
- S15: exit 0 on three runs; 3 containers; vote -> result; tally 0 -> 1; review CONCERNS, all
  four addressed (52170d3)
- S16: the R-check rework (e8c2b4e) plus the review's two concerns (3cdd4b6). The negative
  test (/tmp/s16-negative2.log) proves the failure path now fails loudly instead of comparing
  two empty reads, and leaves the worker running

## In progress
- none — the S16 review box is the human's to tick (CONCERNS with no blockers, both
  addressed); S17 must not start until then

## Blocked
- none

## Learnings
- "Rework the six checks the migration invalidates" was an incomplete inventory: R3/R4/R6/R7
  broke through the shared `psql_q`/`redis_q` helpers and R7's direct exec. Grep for the
  helper, not the requirement number.
- A stale gate's green can be latency, not health: S00.sh passed only while the pre-migration
  app happened to still be running in `default`.
- A guard is not a fix if it skips the cleanup: R8's new early `fail` left the worker at 0
  replicas because the restore lived in the branch it bypassed.
- `int(outputs.get("port", "6379"))` gives `jit-pgadmin` redis's port; the pgadmin module has
  no `port` output.
- kustomize refuses an overlay whose `resources:` reaches a directory containing the overlay;
  use a sibling subtree (base/ + overlays/ -> ../../base)
- R12 seds the registry hostname in instead of building the overlay, so only
  `kubectl kustomize <overlay>` catches a broken one
- `tofu output` renders a sensitive value as "<sensitive>" — never route a secret through a
  module output while the runner parses plain text
- Failed is terminal until the Deployment changes; leave a claim pending, not failed
- Heredocs are flaky in this tool shell; write the payload to a /tmp file instead
