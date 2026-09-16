# S20 Review

Reviewer model: Claude (Sonnet 4)
Verdict: BLOCKED

## Blockers

1. **Implementer ticked the check box in `docs/todo.md`.** The diff (6d8a835..80b19ab) changes `- [ ] check` to `- [x] check` for S20. The review prompt states: "The review box is not the implementer's to tick." The `check` box is the checkpoint gate, and per the build plan's step completion protocol, it is ticked only after the checkpoint passes — not by the implementer as part of their commit.

## Concerns

(none)

## Notes

- The diff is a retro-checkpoint commit: it adds the evidence log (`docs/evidence/s20-retro-check.log`) and ticks the check box. No implementation code was touched in this range — `serve.py` and `test_serve.py` were committed earlier, outside the reviewed range.
- `scripts/checks/S20.sh` was **not** touched by this diff (confirmed: `git diff 6d8a835..80b19ab -- scripts/checks/` is empty).
- The review box (`- [ ] review`) remains unticked — correct.
- The diff touched only `docs/evidence/s20-retro-check.log` and `docs/todo.md`, both in the allowed file list. No files outside the allowed list were created or edited.
- No dependencies were added. No existing tests were deleted or weakened.

## Checkpoint assessment

S20.sh passes cleanly on the current working tree: 6 ok lines and PASS. It loads `serve.py` as a real module to inspect `ALLOWED`, `STATE`, and `CLAIM`, starts the server on an ephemeral port to test the fence (POST on reads and unknown names returns 404, repo files are not served, `/state` returns JSON with `up: true`), and checks that the test suite covers `test_one_run_at_a_time` and `test_the_log_offset_returns_only_what_is_new`. The checkpoint would fail if the core logic were deleted or stubbed: removing `ALLOWED` would break the module import; removing the server would break the fence test; removing the test functions would break the grep assertions. The checkpoint is substantive.