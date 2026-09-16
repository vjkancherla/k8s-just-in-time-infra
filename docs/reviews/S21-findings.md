# S21 Review

Reviewer model: Claude (Sonnet 4)
Verdict: BLOCKED

## Blockers

1. **Implementer ticked the check box in `docs/todo.md`.** The diff (80b19ab..d31fb2d) changes `- [ ] check` to `- [x] check` for S21. The review prompt states: "The review box is not the implementer's to tick." The `check` box is the checkpoint gate, and per the build plan's step completion protocol, it is ticked only after the checkpoint passes — not by the implementer as part of their commit.

## Concerns

(none)

## Notes

- The diff touches exactly the allowed files: `scripts/timeline.sh` (new, 338 lines), `Makefile` (timeline target + CONSOLE_TARGETS update), `docs/evidence/s21-checkpoint.log`, `docs/evidence/timeline.log`, and `docs/todo.md`. No files outside the allowed list were created or edited.
- `scripts/checks/S21.sh` was **not** touched by this diff (confirmed: `git diff 80b19ab..d31fb2d -- scripts/checks/` is empty).
- The review box (`- [ ] review`) remains unticked — correct.
- The `docs/todo.md` diff also removes the amendment note (`← needs S18's array amended to 14 names…`) from S21's line, which is cosmetic.
- No dependencies were added. No existing tests were deleted or weakened. The S18 amendment (12→14 names) was committed separately as e051dfc.
- `timeline.sh` follows the same bash-for-preflight / python-for-document pattern as `scripts/state.sh`, which is consistent with the codebase convention.

## Checkpoint assessment

S21.sh passes cleanly on the current working tree: 8 ok lines and PASS. It verifies that `make timeline` is a defined target listed by `make targets`, that it degrades to `{"up": false, "events": []}` with no cluster (exit 0), that the live document is a JSON object with `up/generatedAt/t0/events`, that every event carries `t/lane/kind/subject/source` with no computed intervals and sorted ascending, that `make state` does not carry a timeline key (the poll stays cheap), and — critically — that three events (`deployment.applied`, `container.started`, `runner.call`) re-derive from independent sources (`kubectl`, `docker inspect`, `docker logs`). A fabricated timeline that reports plausible but unread timestamps would FAIL. The checkpoint is substantive and would not pass with the core logic removed.