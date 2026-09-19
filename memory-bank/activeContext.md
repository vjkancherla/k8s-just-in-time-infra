Updated: 2026-09-19

## Current focus
Automate the demo-mode toggle so `make demo-up` ends with unlimited voting enabled.

## Blocked
- scripts/checks/S18.sh:147 asserts redis stays Ready "because the worker still references it". Unblocking still needs approval to edit a file under scripts/checks/. (Not changed by this task.)

## Done (verified)
- Option A implemented: the demo app consumes all infrastructure connection URLs from the controller-written module Secrets.
- Added `ALLOW_MULTIPLE_VOTES` env var to `app/vote/app.py`: when set to `"true"`, every POST generates a fresh `voter_id`, so repeated clicks from the same browser count as separate votes.
- Exposed `ALLOW_MULTIPLE_VOTES` in `app/kustomize/base/vote-deployment.yaml` (default `"false"` to keep R3 passing).
- Documented the toggle in `app/docs/MANUAL-TESTING-GUIDE.md` §9 with the `kubectl set env` command.
- Static validation: `python3 -m py_compile app/vote/app.py` and `kubectl kustomize app/kustomize/base` both PASS.
- Automated Option A:
  - `scripts/demo-up.sh` now verifies with `ALLOW_MULTIPLE_VOTES=false`, then patches the vote Deployment to `true` and waits for rollout.
  - Root `Makefile` `demo-redeploy` target re-enables demo mode after re-applying the overlay.
  - Updated `app/docs/MANUAL-TESTING-GUIDE.md` to say `make demo-up` auto-enables demo mode.
  - `bash -n scripts/demo-up.sh` and `make -n demo-redeploy` both PASS.

## Checkpoints
- None pending for this task.

## Next step
User can run `make demo-up` — it will pass verification and end with `ALLOW_MULTIPLE_VOTES=true` on the vote Deployment.

## Watch out
- Existing namespaces created before this change have Secrets without `service_url`; redeploying those pods with the new manifests will fail until the namespace is recreated or the Secrets are patched.
- app/*/Dockerfile COPYs templates into the image: a template edit needs a rebuild.
- console/serve.py writes each run to docs/evidence/console-<name>.log; the browser suite redirects serve.EVIDENCE to a temp dir. Keep that swap.
- CSS uppercases `.docker-table th` and `.tiny-tag`: compare inner_text lowercased.
- pgadmin's lease is on vote deliberately; moving it breaks the orphaning demo.
- refs/cline/checkpoints/* snapshot .env and terraform.tfstate; never `git push --all`/`--mirror`.
