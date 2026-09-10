Updated: 2026-09-10

## Working
S14 review returned BLOCKED (B1, B2). Both blockers are fixed and verified live; the
checkpoint was re-run and passes. Awaiting re-review. Nothing ticked.

## Done (verified)
- S0-S13: all checkpoints pass, committed
- S13: IPAM — CLEAR
- S14 checkpoint: `bash scripts/checks/S14.sh` → PASS, exit 0, 0 FAIL lines (three runs)
- Service DNS path verified independently: `getent hosts jit-redis.<ns>.svc.cluster.local`
  → 172.19.0.120, `redis-cli PING` → PONG
- B1 fixed: `destroy_infra` reads the body and accepts only `destroyed`/`not_found`. Proven
  live — destroying a bogus module logs `Destroy reported failure … {'status':'error', …}`
- B2 fixed: `ParamsConflict` condition (reason `FirstWriterWins`) naming both writers, plus
  `status.conditions` in the CRD. Proven live: two writers with different params → condition
  names both; cleared once the losing Deployment was deleted
- `spec.params` now persists (`x-kubernetes-preserve-unknown-fields`), so the winner's params
  are readable — this was a prerequisite for B2

## In progress
- S14 re-review: the reviewer rewrites `docs/reviews/S14-findings.md` against these fixes

## Blocked
- none

## Learnings
- The runner returns HTTP 200 for logical failures — never key success off the status code
- CRD `type: object` with no `additionalProperties`/preserve-unknown-fields prunes nested keys
  (`spec.params` was always `{}`), which also hid the winner's params from conflict detection
- A CRD status field must be declared in the schema before the controller can store it
- kopf fires `on.create` + `on.update` for one Deployment change and the runner has no
  mutex (its `status=="running"` guard is dead code) — concurrent tofu applies collide
- A `Failed` claim is re-provisioned every resync tick while a Deployment references it
- `gcr.io/google_containers/pause:3.5` no longer exists → ErrImagePull; a "pod not Running"
  assertion is vacuous with it
- Always pass `-n "$NAMESPACE"` in checkpoints; `--ignore-not-found` hides a no-op against
  the empty context namespace (`default`)
- Use `git --no-pager`; heredocs break in this zsh shell — write `/tmp/x.sh` with the editor
  and `bash /tmp/x.sh > log 2>&1`; background with `nohup ... &` then poll (no `setsid`)
