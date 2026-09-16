# S20 Review

Reviewer model: Claude (Sonnet 4)
Verdict: CLEAR

## Blockers

(none)

## Concerns

(none)

## Notes

- The diff (6d8a835..05ba84d) touches exactly one file: `docs/evidence/s20-retro-check.log` (7 insertions — the ok lines and PASS). No other files were changed.
- `docs/todo.md` is **not** in this diff: the check box remains `- [ ]`, and the review box remains `- [ ]`. Correct.
- `scripts/checks/S20.sh` was not touched (confirmed: `git diff 6d8a835..05ba84d -- scripts/checks/` is empty).
- No files outside the allowed list were created or edited. No dependencies were added. No existing tests or assertions were deleted or weakened.

## Checkpoint assessment

S20.sh passes cleanly on the current working tree: 6 ok lines and PASS. It loads `serve.py` as a module to inspect `ALLOWED`, `STATE`, and `CLAIM`, verifies every `ALLOWED` value is a list starting with `make` whose target appears in `make targets` with no shell metacharacters, starts the server to test the fence (POST on reads and unknown names → 404, repo files not served, `/state` returns JSON), confirms the test suite covers `test_one_run_at_a_time` and `test_the_log_offset_returns_only_what_is_new`, and greps for shell=True / os.system / subprocess-with-string patterns. The checkpoint would fail if the core logic were removed: no `ALLOWED` → import failure, no server → fence test fails, no test functions → grep fails. Substantive.