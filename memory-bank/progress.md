Updated: 2026-10-09

## Working
S15 is done and reviewed: CONCERNS with no blockers, all four addressed (52170d3). The app runs on JIT
infra with no stateful workload in the cluster.

## Done (verified)
- S0-S13: checkpoints pass, committed
- S14: real provisioning via the runner; review CLEAR, one item UNVERIFIED
- S15: exit 0 on three runs; 3 containers; vote -> result; tally 0 -> 1
- S15's four review concerns addressed: module note, S00 annotation, carried-forward flags recorded

## In progress
- none — S16 has not been started, and must not start until the human ticks S15's review box

## Blocked
- none

## Learnings
- kustomize rejects an overlay whose `resources:` reaches a directory containing the overlay itself;
  use a sibling subtree (base/ + overlays/ with `resources: ../../base`)
- R12 seds the registry hostname into the base instead of building the overlay, so a broken overlay
  still passes `make verify`; only `kubectl kustomize <overlay>` catches it
- `tofu output` in plain text renders sensitive values as "<sensitive>" — never route a secret through
  a module output while the runner parses plain text
- Failed is terminal until the Deployment changes; leave a claim pending when a dependency is not ready
- A gate that parses an artifact instead of producing it can pass on stale state (S00 + verify.md)
- app/ and scripts/checks/S00-S07.sh were never committed; git history lacks the app source
- Heredocs are flaky in this tool shell; write the payload to a /tmp file instead
