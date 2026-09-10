Updated: 2026-09-10

## Working
S14 is complete: blockers, all 10 concerns, the IPAM + postgres defects and the tfstate/leak
defect are fixed. S13 and S14 checkpoints PASS with 0 FAIL on the final code.

## Done (verified)
- S0-S13: all checkpoints pass, committed
- S13: IPAM — CLEAR
- S14 checkpoint: PASS on five runs; latest carries the strengthened Phase 2 (Service name),
  Phase 3 (pod gated on the JIT Secret) and Phase 4 (cold destroy asserted to remove the
  container) assertions. B1/B2 in 2e74e04
- Concerns verified live: 1 attempt vs 2/100s on a Failed claim; 1 apply + 0 collisions with
  two writers on one claim; `status.message` cleared on recovery; multi-module runner keying
- IPAM per-claim addressing + claim-count fix, and postgres `sensitive = true`
- All three modules now declare `backend "s3" {}`: state really is in MinIO, and a cold
  destroy removes the container (1 → 0) instead of reporting success and leaking it
- S13 and S14 both re-verified PASS after every one of those changes

## In progress
- S14 re-review against the newest commit

## Blocked
- none

## Learnings
- No module declares a `backend` block, so the runner's `-backend-config` args are ignored:
  tofu used local state in a temp dir, so cold destroys were no-ops that reported success
- The runner image has no docker CLI, so its `docker rm -f` "safety" is dead code inside `except Exception: pass`
- S13.sh's `kubectl set env` leaves the controller mutated (empty RUNNER_TOKEN, wrong WATCH_NAMESPACES) — re-apply deploy/controller.yaml before S14
- The runner returns HTTP 200 for logical failures — read the body, not the status code
- A CRD `type: object` with no additionalProperties/preserve-unknown-fields prunes that field
- `docker inspect <name>` also matches the IMAGE, so existence checks need
  `docker container inspect`
- `VAR="$(grep ... )"` under `set -e` aborts the script when grep matches nothing — add `|| true`
- kopf fires on.create + on.update for one Deployment change: dedupe with a per-claim lock
- Rebuild the runner image (and recreate the container) to ship runner code — main.py is baked
  into the image; only jit-modules is bind-mounted
- Heredocs and shell-integration output are flaky in this tool shell; prefer /tmp scripts and
  `nohup ... &` then poll
