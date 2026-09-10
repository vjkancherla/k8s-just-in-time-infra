Updated: 2026-10-09

## Current focus
S15 checkpoint PASSED and committed (bf77a21). Waiting on the human: the review prompt cannot be
generated because docs/reviews/REVIEW-PROMPT-TEMPLATE.md does not exist.

## Done (verified this pass)
- Wrote scripts/checks/S15.sh, S16.sh, S17.sh from build-plan.md and committed (c2e01a0) — S-1 was incomplete.
- S15: app migrated off in-cluster state. `bash scripts/checks/S15.sh` -> 16 PASS, exit 0, ran twice
  (/tmp/s15-verify.log). Three containers provisioned, vote -> result end to end, tally 0 -> 1.
- Kustomize restructured: base/ + overlays/{registry,voting-a,voting-b}; the registry overlay now builds.
- Controller generates the Postgres password once per namespace, writes it into jit-postgres as
  POSTGRES_PASSWORD, shares it with pgadmin; a cold destroy reads it back from the Secret.

## Checkpoints (final code)
- PASS: S15 exit 0 (/tmp/s15-verify.log) · S13 (/tmp/s13-b.log) · S14 (/tmp/s14-backend.log)

## Commits
bf77a21 S15 migration · c2e01a0 S-1 checks · 354f8bc memory bank · 1b50388 S14 review prompt

## Next step
Decide how to produce docs/reviews/S15-review-prompt.md without the template, then run the S15 review.

## Watch out
- docs/reviews/REVIEW-PROMPT-TEMPLATE.md has NEVER existed, so the 12-question protocol cannot be followed.
- Frozen S00.sh is now stale: it asserts 5 workloads and 17 PASS, both invalidated by S15 (S16 fixes verify.sh).
- app/scripts/verify.sh, app/vote, app/worker, app/result are still uncommitted; scripts/checks/S00-S07.sh too.
- No run-all.sh or review-guard.sh exists.
- pgadmin publishes a fixed host port 5050, so S17's two namespaces cannot both run it.

