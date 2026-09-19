Updated: 2026-09-19

## Current focus
demo-undeploy deletes all three app Deployments now. One frozen S18 assertion needs the
human's approval to amend before that checkpoint can pass again.

## Blocked
- scripts/checks/S18.sh:147 asserts redis stays Ready "because the worker still references
  it". Unblocking needs approval to edit a file under scripts/checks/.

## Done (verified)
- `make demo-undeploy` deletes voting-app-{vote,worker,result} in DEMO_NS, mirroring what
  demo-redeploy starts. `make -n` prints the new command, `make targets` is unchanged, and
  the S18 target-name assertion still passes.
- Wording corrected in the Makefile, console/index.html (description only - the button
  label is kept, six docs quote it as a story beat), console/README, JIT-MAKEFILE-GUIDE,
  deletion-lifecycle.md and console-demo-test-plan.md.
- Browser suite realigned to the action-card rework; 69 tests pass.
- The VOTE header is removed from both app templates.

## Checkpoints
- S18 cannot pass until the redis assertion is amended: undeploy now removes every referrer.

## Next step
Decide the S18 redis assertion (see Blocked), then commit the working tree.

## Watch out
- O11 is now visible: the Setup sub-line hardcodes "one on the clock" while the LED counts
  ("3 on the clock"). `test_the_setup_subtitle_counts_claims_and_containers` asserts the
  singular wording, so it moves with any fix.
- Every claim orphans on undeploy now, so a lapsed 10m window destroys redis and postgres.
- app/*/Dockerfile COPYs templates into the image: a template edit needs a rebuild.
- console/serve.py writes each run to docs/evidence/console-<name>.log; the browser suite
  redirects serve.EVIDENCE to a temp dir. Keep that swap.
- CSS uppercases `.docker-table th` and `.tiny-tag`: compare inner_text lowercased.
- pgadmin's lease is on vote deliberately; moving it breaks the orphaning demo.
- refs/cline/checkpoints/* snapshot .env and terraform.tfstate; never `git push --all`/`--mirror`.
