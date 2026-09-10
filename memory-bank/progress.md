Updated: 2026-10-09

## Working
S-1 completed for the three missing gates (c2e01a0). S15 itself is blocked on one design
question: the registry overlay its gate must build does not build.

## Done (verified)
- S0-S13: all checkpoints pass, committed
- S14: real provisioning via the runner; review CLEAR, one item UNVERIFIED (conflicting params)
- S15/S16/S17 checkpoint scripts written from build-plan.md and verified to fail cleanly
- Controller + runner + MinIO up; pre-migration app still running in `default`

## In progress
- S15: waiting on the registry-overlay decision before any manifest changes

## Blocked
- S15 — one question, one answer needed. See activeContext "Current focus".

## Learnings
- kustomize rejects an overlay whose `resources:` reaches a directory that contains the
  overlay itself ("cycle detected"); overlays must live outside the base tree
- `kubectl kustomize <overlay>` is the only honest test of an overlay — R12 seds the base
  instead, so a broken overlay passes `make verify`
- S00-S07 checkpoints were never committed, so S-1's freeze never covered them
- No module declares a `backend` block, so the runner's `-backend-config` args are ignored:
  tofu used local state in a temp dir, so cold destroys were no-ops that reported success
- The runner returns HTTP 200 for logical failures — read the body, not the status code
- `docker inspect <name>` also matches the IMAGE, so existence checks need `docker container inspect`
- `VAR="$(grep ... )"` under `set -e` aborts when grep matches nothing — add `|| true`
- kopf fires on.create + on.update for one Deployment change: dedupe with a per-claim lock
