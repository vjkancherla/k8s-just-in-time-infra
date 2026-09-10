Updated: 2026-10-09

## Current focus
S15 review returned CONCERNS with no blockers (docs/reviews/S15-findings.md). All four concerns are
addressed in 52170d3. Waiting on the human to tick the S15 review box.

## Done (verified this pass)
- S15: app migrated off in-cluster state. `bash scripts/checks/S15.sh` -> exit 0 on three runs
  (/tmp/s15-verify.log, /tmp/s15-final.log). Three containers, vote -> result, tally 0 -> 1.
- Review concerns: a note in the postgres module against owning the password (item 5), S00.sh
  annotated rather than re-opened (item 9), pgadmin port + SECRET_KEY recorded as flags (items 10, 11).
- docs/lessons.md created — the file build-plan.md's "Done" and docs/todo.md both point at.

## Checkpoints (final code)
- PASS: S15 exit 0 · S13 (/tmp/s13-b.log) · S14 (/tmp/s14-backend.log)

## Commits
52170d3 review concerns · 3bd9806 S15 review prompt · bf77a21 S15 migration · c2e01a0 S-1 checks

## Next step
The human ticks S15's review box in docs/todo.md, then S16 reworks the R-checks the migration broke.

## Watch out
- S00.sh passes misleadingly today: it inspects the pre-migration app in `default` and parses a stale
  verify.md. It starts failing when the migrated app is deployed (S16).
- S00.sh is now tracked; scripts/checks/S01-S07.sh are still untracked.
- pgadmin's fixed host port 5050 blocks S17's two namespaces — see docs/todo.md "Flags carried forward".
- docs/reviews/REVIEW-PROMPT-TEMPLATE.md still does not exist.


