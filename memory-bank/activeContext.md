Updated: 2026-10-09

## Current focus
S16 is implemented and its checkpoint passes (exit 0, three runs). `make verify` is 17 PASS
again against out-of-cluster infra. Waiting on the S16 review; S15's review box is still
unticked in docs/todo.md.

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

## Checkpoints (final code)
- PASS: S16 (exit 0 x3, /tmp/s16-run{1-keep,2,3}.log) · S15 (/tmp/s15-final.log)
- FAIL (expected): S00.sh — stale assertion, documented in docs/todo.md flags

## Commits
e8c2b4e S16 rework · abcafd6 S16 review prompt · 1a4fccf S15 concerns · bf77a21 S15 migration

## Next step
The human runs the S16 review with a different model; S17 starts only after CLEAR.

## Watch out
- `jit-pgadmin` Service advertises 6379 (controller default) — S17's, invisible to R1-R17.
- pgadmin's fixed host port 5050 still blocks S17's two namespaces.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` still does not exist; S16's prompt is house-style.
- `app/scripts/build.sh`, `app/vote/`, `app/worker/` and `scripts/checks/S01-S07.sh` remain
  untracked.



