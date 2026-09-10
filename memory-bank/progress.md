Updated: 2026-09-10

## Working
S14 blockers fixed and all 10 review concerns addressed; checkpoint re-run PASS, 0 FAIL.
Two new defects found (IPAM per-claim IP, postgres module) awaiting a decision.

## Done (verified)
- S0-S13: all checkpoints pass, committed
- S13: IPAM — CLEAR
- S14 checkpoint: PASS on three runs; the latest carries the strengthened Phase 2 (Service
  name) and Phase 3 (pod gated on the JIT Secret, `CreateContainerConfigError`) assertions
- S14 blockers B1/B2 committed 2e74e04; concerns 1-10 addressed in the next commit
- Concerns verified live: 1 attempt vs 2/100s on a Failed claim; 1 apply + 0 collisions with
  two writers on one claim; `status.message` cleared on recovery; multi-module runner keying

## In progress
- S14 re-review against the newest commit

## Blocked
- Multi-module namespaces: every claim in a namespace gets the same `allocatedIP`, so redis +
  postgres in one namespace collide. Blocks S15. Raised, not fixed (it touches S13).

## Learnings
- The runner returns HTTP 200 for logical failures — read the body, not the status code
- A CRD `type: object` with no additionalProperties/preserve-unknown-fields prunes that field
- `allocate_block(ns)` allocates one block per namespace, but callers hand its base IP to every
  claim — the block's 10 addresses were never used per-claim
- `docker inspect <name>` also matches the IMAGE, so existence checks need
  `docker container inspect`
- `VAR="$(grep ... )"` under `set -e` aborts the script when grep matches nothing — add `|| true`
- kopf fires on.create + on.update for one Deployment change: dedupe with a per-claim lock
- Rebuild the runner image (and recreate the container) to ship runner code — main.py is baked
  into the image; only jit-modules is bind-mounted
- Heredocs and shell-integration output are flaky in this tool shell; prefer /tmp scripts and
  `nohup ... &` then poll
