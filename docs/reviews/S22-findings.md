# S22 Review

Reviewer model: Muse Spark (opencode/muse-spark-1.3-contributor-free)
Verdict: CLEAR

Prompt intact: yes — twelve numbered questions, verified by count. There is no
`scripts/checks/S22.sh` by design, so per the prompt's S22 notes I used the
all-fail capture (`docs/evidence/s22-all-fail.log` plus `docs/evidence/S23.log`
-`S29.log`) as the Q6/Q7 equivalent. I re-ran each checkpoint myself to
reviewer logs under `/tmp` so committed evidence was untouched, and restored
the one side effect of my run (`docs/evidence/state.log`, rewritten by S29's
`make state` probe). Range under review: `f0cdde0..c7ecc07` (29 files, 2031
insertions, 3 deletions).

## Blockers

None.

Q-by-Q mechanical record:

1. `scripts/checks/` touched, but only the S22-owned paths
   (`S23.sh`-`S29.sh` new, `lint-helpers.sh` new) — the prompt's Q1 note
   expressly carves out these creations. A name search of the range for
   `S01`-`S21.sh`, `.clinerules/`, CI, and scanner paths returns nothing.
2. No dependency added. `Makefile` gains only the `gate` target (4 lines) next
   to the untouched `check` target; `opencode.json` is a 4-line instructions
   pointer. No manifest, module, or package change.
3. Nothing deleted or weakened. The 3 deletions are: the build-plan `## Done`
   header replaced by the Stage H section (2), and the design's stale
   "`scripts/checks/S22.sh`" sentence swapped 1-for-1 to `S29.sh` (1,
   sanctioned by ADR 0006). Post-freeze checkpoint edits (S23 verdict, S24
   destroy pairs, S26 conflict/apply/cleanup/`-gt`/`kill 0`, S29
   preconditions/U12/`kk`, S29 suite gate) are each sanctioned by ADR 0005 or
   ADR 0006 and committed with them.
4. The only file in the range outside the allowed list is
   `docs/reviews/S22-review-prompt.md` itself, via prompt-only commits inside
   the span — review machinery, exempted by the prompt's Q4 note. Every
   implementation file is listed.
5. `docs/todo.md`: S22 reads `[x] check - [ ] review`; S23-S29 rows unticked.
   The check tick is the implementer's; the review box is unticked.

Q6: all seven checkpoints FAIL readably on the current tree, each a `FAIL:`
naming its precondition, matching the committed `s22-all-fail.log` (itself
regenerated at `e8ab404`): S23 spike-log missing, S24/S27 runner down,
S25/S26 CRD missing, S28 consumer-shape, S29 `make state up=False`. `bash -n`
clean on all seven plus runner, guard, summarizer, and lint helper;
`lint-helpers.sh` prints PASS; `review-guard.sh 22
docs/evidence/s22-all-fail.log` prints PASS.

Q7 (inverted for this pre-flight step): every checkpoint carries an assertion
a correct implementation could satisfy once S23-S29 build it — S23's exact
`VERDICT: maxmemory mutable|refused` match (`S23.sh:29-35`), S24's both sides
of the conditional `state rm` (`S24.sh:41-63`), S25's CRD round-trip plus
`DECLARED` column (`S25.sh:18-35`), S26's `ParamsConflict` naming both
declarers and clearing on agreement (`S26.sh:86-104`), S27's destroy path,
S28's kustomize builds + `git grep` scans + `tofu fmt -check` + three
design-line greps (`S28.sh:9-78`), S29's U1-U13 plus the suite gate. None is a
placeholder.

## Concerns

None.

## Notes

- The S29 suite gate (ADR 0006 item 3) is placed correctly: the `make verify`
  17-PASS and `make jit-verify` J1-J11 assertions (`S29.sh:292-319`) run before
  the U12 namespace deletion (`S29.sh:321`), which destroys the `voting-a`
  both suites need alive. With nothing implemented the script fails at the
  earlier `make state` precondition, so the gate ordering is untested until
  S29 runs live — expected for a pre-flight step, recorded here so the S29
  reviewer checks it.
- `RUNBOOK.md`, `opencode.json`, `.opencode/rules/s22-declarers.md` go beyond
  the design's Verification section, but they encode the Stage-H protocol the
  build plan states and are on the allowed list. The rules file restates
  design defaults instead of citing them; a drift risk for later steps, not
  this one.
- Inherent to frozen pre-flight gates, not S22 defects: S23's spike log is
  self-reported measurements (nothing in the harness proves the timings were
  measured); S28's doc-amendment checks are substring greps a vacuous line
  could satisfy. Both are properties the S23/S28 reviewers must probe live.
- Attack-first answer: S23's `VERDICT:` line — a fabricated verdict without
  measurements passes the checkpoint while hollowing out U1's foundation.
  Second: S28's doc greps. The freshness gate in `s22-all-fail.sh` and the
  runner's dirty-checkpoint refusal close the evidence-forgery angles at this
  layer.

## Checkpoint assessment

S22's record is sound and I reproduced it: all seven child checkpoints,
re-run through `scripts/checkpoint.sh` to reviewer logs on the current tree,
fail with readable `FAIL:` lines naming their preconditions, zero syntax
errors, lint and review-guard PASS — exactly what the committed
`s22-all-fail.log` claims. Each script asserts its step's contract (now
including S29's suite-survival gate, correctly ordered before U12), the two
ADRs sanction every post-freeze edit, and the design's stale checkpoint path
is corrected, so the frozen set can plausibly go green as S23-S29 are built.
CLEAR.
