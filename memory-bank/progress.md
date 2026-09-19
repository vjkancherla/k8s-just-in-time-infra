Updated: 2026-09-19

## Working
Nothing. demo-undeploy's change is verified in the Makefile, but the checkpoint that covers
it now fails by design.

## Done (verified)
- `make demo-undeploy` deletes voting-app-{vote,worker,result} in DEMO_NS, mirroring what
  demo-redeploy starts. `make -n` prints the new command, `make targets` is unchanged, the
  S18 target-name assertion still passes, and the console renders with no page errors.
- Wording updated: Makefile help, console/index.html (description only; the button label is
  kept), console/README, JIT-MAKEFILE-GUIDE, deletion-lifecycle.md, console-demo-test-plan
  (demo table, item 1, O11).
- Browser suite realigned with the action-card rework in console/index.html: 69 tests pass.
- The VOTE header is removed from both app templates, with the offset that cleared it.

## Broken (confirmed by execution)
- scripts/checks/S18.sh:147 - "redis did not stay Ready - worker still references it" cannot
  pass while undeploy removes all three Deployments: every claim orphans now. The check is
  frozen, so amending it needs the human's approval.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data
  directory, container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks
  fail; `ipam.py` has no lock.
- No gate covers volume removal on destroy any more: J6 asserts the volume stays.

## In progress
Nothing.

## Blocked
- The S18 redis assertion (see Broken) - awaiting the human.

## Learnings
- CSS text-transform reaches Playwright's inner_text: assert on the rendered casing.
- serve.py writes every run to docs/evidence/console-<name>.log, so a suite run overwrote
  real evidence; Console.__enter__ now redirects it to a temp dir.
- The referrer map is the demo: redis and postgres survived an undeploy only because worker
  and result named them, so removing all three Deployments arms every clock at once.
