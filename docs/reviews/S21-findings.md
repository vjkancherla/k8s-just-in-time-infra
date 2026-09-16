# S21 Review

Reviewer model: Claude (Sonnet 4)
Verdict: CLEAR

## Blockers

(none)

## Concerns

(none)

## Notes

- The diff (05ba84d..ae5e544) touches exactly the allowed files: `scripts/timeline.sh` (new, 338 lines), `Makefile` (timeline target + CONSOLE_TARGETS update), `docs/evidence/s21-checkpoint.log`, `docs/evidence/timeline.log`, and `docs/todo.md`. The `docs/todo.md` change removes the amendment note from S21's line; both check boxes remain `- [ ]`.
- `scripts/checks/S21.sh` was not touched (confirmed: `git diff 05ba84d..ae5e544 -- scripts/checks/` is empty).
- No dependencies were added. No existing tests or assertions were deleted or weakened. The S18 amendment (12→14 names) was committed separately (e051dfc / eecb02e).
- `timeline.sh` follows the same bash-for-preflight / python-for-document pattern as `scripts/state.sh`, consistent with the codebase convention.

## Checkpoint assessment

S21.sh passes cleanly on the current working tree: 8 ok lines and PASS. It verifies `make timeline` is a defined target listed by `make targets`, degrades to `{"up": false, "events": []}` with no cluster (exit 0), emits a JSON object with `up/generatedAt/t0/events`, every event carries `t/lane/kind/subject/source` with no computed intervals and sorted ascending, `make state` does not carry a timeline key (the poll stays cheap), and — critically — three events (`deployment.applied`, `container.started`, `runner.call`) are re-derived from independent sources (`kubectl`, `docker inspect`, `docker logs`). A fabricated timeline reporting plausible but unread timestamps would FAIL. The checkpoint is substantive and would not pass with the core logic removed.