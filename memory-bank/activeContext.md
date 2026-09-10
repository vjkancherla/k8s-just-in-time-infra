Updated: 2026-10-09

## Current focus
S16's review came back CONCERNS with no blockers (docs/reviews/S16-findings.md, e17afc7).
Both concerns are fixed in 3cdd4b6 and the checkpoint re-passes 17 PASS. Waiting on the
human to tick S16's review box in docs/todo.md.

## Done (verified this pass)
- S16: `app/scripts/verify.sh` reworked — `psql_q`/`redis_q` read the stateful tiers with
  `docker exec` (`default-redis-redis`, `default-postgres-postgres`); R9 is
  `docker restart` + `pg_isready`; R10/R11 count 3 and are namespace-scoped; R16 posts into
  the container; R17 reads the `jit-postgres` outputs Secret. R7 also changed (it called
  `kubectl exec "$PGPOD"` directly); R3/R4/R6 came along through the helpers. R1, R5 and
  R12-R15 untouched.
- The migrated app now runs in `default` (pre-migration app torn down there), so S00.sh
  fails honestly as its stale header predicted.
- `app/docs/MANUAL-TESTING-GUIDE.md` updated wherever it mirrored a reworked check.
- New S17 flag: the controller's Service port default gives `jit-pgadmin` 6379.
- S16 review CONCERNS (both fixed in 3cdd4b6): the helper reads are guarded so two failures
  cannot compare equal, and R8's worker restore runs on every path — the first version of
  the guard skipped it and left the worker at 0 replicas. Caught by the negative test
  (/tmp/s16-negative2.log), not by the checkpoint. build-plan.md's "eleven unaffected"
  corrected in place (eleven invalidated, six unaffected).

## Checkpoints (final code)
- PASS: S16 (exit 0 x3, /tmp/s16-run{1-keep,2,3}.log) · S15 (/tmp/s15-final.log)
- FAIL (expected): S00.sh — stale assertion, documented in docs/todo.md flags

## Commits
3cdd4b6 concern fixes · e17afc7 S16 findings · e8c2b4e S16 rework · abcafd6 review prompt

## Next step
The human ticks S16's review box in docs/todo.md, then S17 reworks the R-checks' remaining
`default` assumptions and adds the JIT suite. S17 must not start until then.

## Watch out
- `jit-pgadmin` Service advertises 6379 (controller default) — S17's, invisible to R1-R17.
- pgadmin's fixed host port 5050 still blocks S17's two namespaces.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` still does not exist; S16's prompt is house-style.
- `app/scripts/build.sh`, `app/vote/`, `app/worker/` and `scripts/checks/S01-S07.sh` remain
  untracked.



