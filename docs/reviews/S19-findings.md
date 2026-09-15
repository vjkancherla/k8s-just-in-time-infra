# S19 Review

Reviewer model: Claude (Opus 4.6)
Verdict: CLEAR

## Blockers

(none)

## Concerns

1. **Assertion 3 is vacuous.** The page no longer names any `make <target>` in prose,
   so the checkpoint's assertion 3 ("every target the page names is defined") always
   passes. The checkpoint documents this intentionally and demonstrates its teeth by
   running against a copy that restores the `make console` reference — but on the
   live tree it catches nothing. If new prose is added naming a target, this assertion
   will not notice unless someone re-runs the evidence copy.

2. **`console/README.md` update is outside the design's "Do" list.** The diff changed
   "Three endpoints" to "Four endpoints" in the README. The design names
   `console/index.html`, `console/README.md`, `Makefile`, and `docs/build-plan.md` as
   touchable — README is in the list, so this is mechanically fine. But the design's
   "Do" section for S19 does not mention a README update. It is a documentation
   correction, not scope creep, and the change is accurate.

## Notes

- The copy-to-clipboard function (`copy(a, btn)`) was removed with the snapshot mode.
  It was only reachable when `S.live === false`, which no longer exists. Its removal is
  clean — no dead code path remains.
- The `S.live` flag gated interactive features (claim cell click, copy, footer text,
  setup subtitle). All are now unconditional, which is correct: the page is always live.
- The boot sequence is now `render()` → `fetch('/state')` → on success start polling.
  If the fetch fails, the page shows "No state. Serve this page from the console process."
  This is the right behaviour for a page that cannot work without the server.

## Checkpoint assessment

`scripts/checks/S19.sh` passes on the current working tree, all 7 assertions green.
Six of the seven assertions catch meaningful regressions: missing external scripts/buttons
(1, 2), wrong endpoint calls (4), missing error handling in poll() (5), and fields the
page reads that `make state` does not emit (6). Assertion 3 is vacuous by design — the
page names no `make <target>` in prose — but the checkpoint documents this, and its
evidence file (`docs/evidence/s19-retro-check.log`) proves the assertion fires when a
`make console` reference is reintroduced. The checkpoint is sound; it would catch the
finding that created this step (the page promised `make console`, which the Makefile
did not define).
