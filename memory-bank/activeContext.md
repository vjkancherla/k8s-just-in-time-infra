Updated: 2026-09-19

## Current focus
Add a demo-mode toggle so one browser can vote repeatedly.

## Blocked
- scripts/checks/S18.sh:147 asserts redis stays Ready "because the worker still references it". Unblocking still needs approval to edit a file under scripts/checks/. (Not changed by this task.)

## Done (verified)
- Option A implemented: the demo app consumes all infrastructure connection URLs from the controller-written module Secrets.
- Added `ALLOW_MULTIPLE_VOTES` env var to `app/vote/app.py`: when set to `"true"`, every POST generates a fresh `voter_id`, so repeated clicks from the same browser count as separate votes.
- Exposed `ALLOW_MULTIPLE_VOTES` in `app/kustomize/base/vote-deployment.yaml` (default `"false"` to keep R3 passing).
- Documented the toggle in `app/docs/MANUAL-TESTING-GUIDE.md` §9 with the `kubectl set env` command.
- Static validation: `python3 -m py_compile app/vote/app.py` and `kubectl kustomize app/kustomize/base` both PASS.

## Checkpoints
- None pending for this task.

## Next step
User can run `make demo-up` (rebuilds the vote image with the new code), then `kubectl set env deployment/voting-app-vote ALLOW_MULTIPLE_VOTES=true -n voting-a` to enable unlimited clicking.

## Watch out
- Existing namespaces created before this change have Secrets without `service_url`; redeploying those pods with the new manifests will fail until the namespace is recreated or the Secrets are patched.
- app/*/Dockerfile COPYs templates into the image: a template edit needs a rebuild.
- console/serve.py writes each run to docs/evidence/console-<name>.log; the browser suite redirects serve.EVIDENCE to a temp dir. Keep that swap.
- CSS uppercases `.docker-table th` and `.tiny-tag`: compare inner_text lowercased.
- pgadmin's lease is on vote deliberately; moving it breaks the orphaning demo.
- refs/cline/checkpoints/* snapshot .env and terraform.tfstate; never `git push --all`/`--mirror`.
