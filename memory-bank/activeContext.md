Updated: 2026-09-19

## Current focus
Option A implemented: the demo app consumes all infrastructure connection URLs from the controller-written module Secrets.

## Blocked
- scripts/checks/S18.sh:147 asserts redis stays Ready "because the worker still references it". Unblocking still needs approval to edit a file under scripts/checks/. (Not changed by this task.)

## Done (verified)
- jit-controller/main.py writes `service_url` (Redis/Postgres DSN), `service_host`, `POSTGRES_DB` and `POSTGRES_USER` into the module Secrets.
- vote/worker/result Deployments source `REDIS_URL` and `DATABASE_URL` from `jit-redis`/`jit-postgres` `service_url`; initContainers source Postgres reachability vars from `jit-postgres`.
- vote/worker/result app code reads `REDIS_URL` and `DATABASE_URL` only — no hardcoded hosts, ports, DB names or users.
- Docs updated: docs/designs/demo-voting-app.md, docs/designs/annotation-to-state.md (new "What each module Secret contains" section), app/docs/SCRIPTS-GUIDE.md, app/docs/MANUAL-TESTING-GUIDE.md, app/kustomize/base/kustomization.yaml.
- `make demo-up` verified end-to-end: `===== 17 PASS, 0 FAIL =====`.
- Committed as `68bec5d`.

## Checkpoints
- None pending for this task.

## Next step
Return to the S18 redis assertion decision, or take the next user request.

## Watch out
- Existing namespaces created before this change have Secrets without `service_url`; redeploying those pods with the new manifests will fail until the namespace is recreated or the Secrets are patched.
- app/*/Dockerfile COPYs templates into the image: a template edit needs a rebuild.
- console/serve.py writes each run to docs/evidence/console-<name>.log; the browser suite redirects serve.EVIDENCE to a temp dir. Keep that swap.
- CSS uppercases `.docker-table th` and `.tiny-tag`: compare inner_text lowercased.
- pgadmin's lease is on vote deliberately; moving it breaks the orphaning demo.
- refs/cline/checkpoints/* snapshot .env and terraform.tfstate; never `git push --all`/`--mirror`.
