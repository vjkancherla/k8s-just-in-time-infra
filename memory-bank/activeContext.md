Updated: 2026-09-17

## Current focus
The annotation realignment is done, verified and re-baselined: 3 manifests, the 4 J-assertion
blocks and 6 docs. Uncommitted; the live cluster runs on a 2m window (see Watch out).

## Blocked
- Nothing.

## Done (verified)
- app/kustomize/base: vote = redis+pgadmin, worker = redis+postgres, result = postgres. Live
  `referencedBy` after the run: redis [vote,worker], postgres [result,worker], pgadmin [vote].
- `make demo-up` exit 0 with R1-R17 = 17 PASS, 0 FAIL; `make jit-verify` = J1-J11 11 PASS,
  0 FAIL (`.workflow/verify-jit.md`, `docs/evidence/jit-verify.log`). J6 swept pgadmin 155s
  after vote was deleted and left redis+postgres up with the postgres data volume present.
- Contract script /tmp/verify_jit_annotations.py 97/97; both overlays kustomize clean, so
  voting-b's jit.infra~1pgadmin patch still resolves.
- Docs realigned: voting-app.md, annotation-to-state.md, deletion-lifecycle.md (incl. the
  2m/10m drift), console-demo-test-plan.md (5 places), SCRIPTS-GUIDE.md; S15-findings.md
  carries a dated amendment instead of editing the review record.

## Checkpoints
- S18 PASS (amended) at eecb02e. S19, S20, S21 ticked + CLEAR. S17 untouched.

## Next step
`make demo-up` restores the 10m demo window - the suite's sed left the live cluster at 2m -
then commit the 11 changed files.

## Watch out
- pgadmin's lease is on vote deliberately: no workload consumes it, and moving it breaks both
  the orphaning demo and voting-b's replace-on-missing-path patch.
- The cluster is live right now with 2m annotations; the demo window in the manifests is 10m.
- Every probe dirtied tracked files (evidence logs); the console's 2s poll rewrites state.log.
- `up` is asked of the cluster: after jit-down the page reads "Nothing is running yet." while
  the cluster and app pods are still there.
- refs/cline/checkpoints/* snapshot .env and terraform.tfstate; never `git push --all`/`--mirror`.
