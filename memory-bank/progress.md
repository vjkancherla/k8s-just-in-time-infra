Updated: 2026-10-09

## Working
S15 complete and committed (bf77a21): the voting app runs on JIT infra with no stateful workload in the
cluster. Blocked only on producing the review prompt.

## Done (verified)
- S0-S13: checkpoints pass, committed
- S14: real provisioning via the runner; review CLEAR, one item UNVERIFIED (conflicting params)
- S15: 16 PASS, exit 0, ran twice; three containers; vote -> result; tally 0 -> 1
- S-1 gate scripts for S15-S17 written and verified to fail cleanly

## In progress
- S15 review - the prompt must exist first

## Blocked
- The S15 review step: docs/reviews/REVIEW-PROMPT-TEMPLATE.md is missing.

## Learnings
- kustomize rejects an overlay whose `resources:` reaches a directory containing the overlay itself;
  overlays must reference a sibling subtree (base/ + overlays/ with `resources: ../../base`)
- R12 seds the registry hostname into the base instead of building the overlay, so a broken overlay still
  passes `make verify`; only `kubectl kustomize <overlay>` catches it
- `tofu output` in plain text renders sensitive values as "<sensitive>", so the runner's parser silently
  returns placeholders - never route a secret back through a module output
- Failed is terminal until the Deployment changes, so a dependency that is not ready yet must leave the
  claim pending, not failed
- app/ and scripts/checks/S00-S07.sh were never committed; git history does not contain the app source
- Heredocs are flaky in this tool shell; write the payload to a /tmp file and pass it as an argument
