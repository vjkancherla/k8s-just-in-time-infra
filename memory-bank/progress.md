Updated: 2026-09-19

## Working
Nothing.

## Done (verified)
- Option A implemented: hardcoded infrastructure URLs removed from app manifests and source code.
- jit-controller/main.py writes `service_url`, `service_host`, `POSTGRES_DB`, `POSTGRES_USER` into module Secrets.
- vote/worker/result Deployments source `REDIS_URL`/`DATABASE_URL` from Secrets; initContainers source Postgres reachability vars from Secrets.
- vote/worker/result app code consumes `REDIS_URL` and `DATABASE_URL` only.
- Docs updated: docs/designs/demo-voting-app.md, docs/designs/annotation-to-state.md (new "What each module Secret contains" section), app/docs/SCRIPTS-GUIDE.md, app/docs/MANUAL-TESTING-GUIDE.md, app/kustomize/base/kustomization.yaml.
- `make demo-up` cold-path verification: `===== 17 PASS, 0 FAIL =====`.
- Committed as `68bec5d`.
- Added `ALLOW_MULTIPLE_VOTES` env var to `app/vote/app.py`: when `"true"`, every POST generates a fresh `voter_id`, so repeated clicks from the same browser count as separate votes.
- Exposed `ALLOW_MULTIPLE_VOTES` in `app/kustomize/base/vote-deployment.yaml` (default `"false"` to keep R3 passing).
- Documented the toggle in `app/docs/MANUAL-TESTING-GUIDE.md` §9 with the `kubectl set env` command.
- Static validation: `python3 -m py_compile app/vote/app.py` and `kubectl kustomize app/kustomize/base` both PASS.

## Broken (confirmed by execution)
- scripts/checks/S18.sh:147 - "redis did not stay Ready - worker still references it" cannot pass while undeploy removes all three Deployments. The check is frozen, so amending it needs the human's approval.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data directory, container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks fail; `ipam.py` has no lock.
- No gate covers volume removal on destroy any more: J6 asserts the volume stays.

## In progress
Nothing.

## Blocked
- The S18 redis assertion (see Broken) - awaiting the human.

## Learnings
- CSS text-transform reaches Playwright's inner_text: assert on the rendered casing.
- serve.py writes every run to docs/evidence/console-<name>.log, so a suite run overwrote real evidence; Console.__enter__ now redirects it to a temp dir.
- The referrer map is the demo: redis and postgres survived an undeploy only because worker and result named them, so removing all three Deployments arms every clock at once.
- Existing namespaces provisioned before this change hold Secrets without `service_url`; redeploying them with the new manifests will fail until the namespace is recreated or the Secrets are patched.
