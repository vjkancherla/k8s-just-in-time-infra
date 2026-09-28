Updated: 2026-09-26

## Current focus
S22 design done: settings changes on provisioned JIT infra - Concept 1 (Converge) selected, documented under `docs/design/`.

## Blocked
- scripts/checks/S18.sh:147 asserts redis stays Ready "because the worker still references it". Unblocking still needs approval to edit a file under scripts/checks/. (Not changed by this task.)

## Done (verified)
- S1-S21 complete (docs/todo.md all checked): demo-mode automation, console read model, and timeline are live.
- S22 design complete: `docs/design/infra-change-flow-brainstorm.md` (decision: Concept 1 - Converge; 6 acceptance criteria) plus full transcript `docs/design/infra-change-flow-transcript.md`.
- Decision: annotation stays sole source of truth; controller syncs `InfraClaim.spec` from the paramSource annotation and re-applies via runner `POST /v1/runs`; new `Updating` phase + `status.paramSource`; advisory `AppRestartRequired` (no controller-initiated restarts).
- v1 scope: `params` + `softDeleteTTL` (`moduleVersion` deferred - runner ignores it). Rollback = re-annotate; failed updates stay in Ready/Failed, never Deleting.

## Checkpoints
- None pending for this task.

## Next step
Add S22 to `docs/build-plan.md` and `docs/todo.md`, then implement the controller spec-sync + update flow in `jit-controller/main.py` with `scripts/checks/S22.sh`.

## Watch out
- Existing namespaces created before this change have Secrets without `service_url`; redeploying those pods with the new manifests will fail until the namespace is recreated or the Secrets are patched.
- app/*/Dockerfile COPYs templates into the image: a template edit needs a rebuild.
- console/serve.py writes each run to docs/evidence/console-<name>.log; the browser suite redirects serve.EVIDENCE to a temp dir. Keep that swap.
- CSS uppercases `.docker-table th` and `.tiny-tag`: compare inner_text lowercased.
- pgadmin's lease is on vote deliberately; moving it breaks the orphaning demo.
- refs/cline/checkpoints/* snapshot .env and terraform.tfstate; never `git push --all`/`--mirror`.
- CRD `status` schema is a closed list: `status.paramSource` needs a CRD edit or the API server prunes it.
- App env vars resolve at container start: a Secret change needs an app restart (advisory condition, not controller-initiated).
