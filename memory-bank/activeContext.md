Updated: 2026-10-09

## Current focus
S16's review came back CONCERNS with no blockers (e17afc7). Both concerns are fixed (3cdd4b6)
and the checkpoint re-passes 17 PASS. Waiting on the human to tick S16's review box in
docs/todo.md.

## Done (verified this pass)
- S16: `app/scripts/verify.sh` reworked for out-of-cluster infra - helpers use `docker exec`,
  R9 uses `docker restart` + `pg_isready`, R10/R11 count 3 and are namespace-scoped, R17 reads
  the `jit-postgres` Secret. R7 plus the helper-dependent R3/R4/R6 came along; R1, R5 and
  R12-R15 untouched. Narrative: journal/2026-10-09.md.
- The migrated app now runs in `default`, so S00.sh fails honestly as its stale header
  predicted.
- Review concerns fixed: guarded helper reads (two failures can no longer agree), R8's worker
  restore on every path, build-plan.md's "eleven unaffected" corrected in place.
- `app/docs/MANUAL-TESTING-GUIDE.md` updated wherever it mirrored a reworked check.

## Checkpoints (final code)
- PASS: S16 (exit 0 x4, /tmp/s16-postfix2.log) · S15 (/tmp/s15-final.log)
- FAIL (expected): S00.sh — stale assertion, documented in docs/todo.md flags

## Commits
3cdd4b6 fixes · e17afc7 findings · e8c2b4e rework · abcafd6 prompt

## Next step
The human ticks S16's review box in docs/todo.md; S17 starts only after that.

## Watch out
- `jit-pgadmin` advertises 6379 (controller port default) and pgadmin's fixed host port 5050
  still blocks S17's two namespaces. Both S17's.
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` still does not exist; S16's prompt is house-style.
- `app/scripts/build.sh`, `app/vote/`, `app/worker/` and `scripts/checks/S01-S07.sh` remain
  untracked.




