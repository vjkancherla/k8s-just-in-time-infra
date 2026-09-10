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
- IPAM per-claim addressing + claim-count fix, and postgres `sensitive = true`. S13 and S14
  both re-verified PASS (0 FAIL) after that change

## In progress
- S14 re-review against the newest commit

## Blocked
- Teardown does not remove containers: no module declares a `backend` block, so tofu runs on
  local state in a throwaway temp dir and a cold destroy returns `destroyed` having done
  nothing. Raised, not fixed (it changes how every module initialises). Blocks S15.
- Multi-module namespaces were blocked by per-claim IP collision — now FIXED (see Done).

## Learnings
- No module declares a `backend` block, so the runner's `-backend-config` args are ignored:
  tofu used local state in a temp dir, so cold destroys were no-ops that reported success
- The runner image has no docker CLI — its `docker rm -f` "safety" is dead code hidden behind
  `except Exception: pass`
- S13.sh's `kubectl set env` mutates the live controller (empty RUNNER_TOKEN, WATCH_NAMESPACES
  =default) and never restores it: re-apply deploy/controller.yaml before running S14
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
