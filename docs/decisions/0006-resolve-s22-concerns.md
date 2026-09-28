# 0006. Resolve the S22 CONCERNS verdict in place (no next design round)

Date: 2026-09-28
Status: accepted

## Context

The independent review of S22 (Muse Spark) returned **CONCERNS** with no blockers and
four concerns. The repo's protocol defines only two outcomes - `BLOCKED` (fix and
re-review) and `CLEAR` (tick and proceed) - and is silent on `CONCERNS`; the standing
pattern (ADR 0005) was to park concerns for "the next design round". The human has
stated plainly: **there is no next design round.** Anything left unresolved now is left
unresolved for good, so the concerns are decisions to be taken and implemented here, not
deferred.

The four concerns, verified against the tree:

1. **The review prompt's Q1 false-positives on every correct S22.** Q1 makes any touch
   of `scripts/checks/` a blocker "no judgement required", while the step's own job is
   to create `scripts/checks/S23.sh`-`S29.sh`. The prompt carries S22 notes for Q6/Q7
   but none for Q1, so a conforming S22 is mechanically blocked by its own prompt.
2. **The reviewed range bundles review-file churn with the implementation.** The range
   includes `docs/reviews/S22-review-prompt.md` and the pure-prompt commits
   (`0495a4a`, `924bc46`, `f418849`, `15143e7`), so a literal Q4 (rule 4) blocks. The
   churn cannot be excluded by re-cutting the range: `e434fc5` edited both
   implementation files and the prompt in one commit, and `0495a4a` is a prompt-only
   commit inside the implementation span - no boundary separates them.
3. **S29's gate is not asserted by `S29.sh`.** `docs/build-plan.md` S29 states the gate
   as "run `make verify NS=voting-a` (17 PASS) and `make jit-verify` (11 PASS) in the
   same run - both logs join the evidence", but `S29.sh` contains no reference to either
   suite. The U-table is covered; the suite-survival gate exists only in prose and
   depends on the implementer remembering two extra runs.
4. **A design line points at a checkpoint that does not exist.** 
   `docs/designs/declarers-and-consumers.md` says "Each check is an assertion in
   `scripts/checks/S22.sh`", but by the build-plan gate there is no `S22.sh`; the
   U-table lives in `S29.sh` (the S29 step records the mapping).

## Decision

Resolve all four now, through this ADR (the repo's sole path for changing a frozen
checkpoint, `.opencode/rules/s22-declarers.md`), and record the design edit it sanctions.

1. **Q1 (prompt).** Regenerate `docs/reviews/S22-review-prompt.md` with a Q1 note: Q1
   does not apply to the `scripts/checks/S23.sh`-`S29.sh` and `scripts/checks/lint-helpers.sh`
   paths this step creates; it applies to any edit of a checkpoint the step did not own
   (`S01`-`S21`), or to `.clinerules/`, CI or scanner config.

2. **Q4 / rule 4 (prompt).** Add a one-line note in the same prompt that
   `docs/reviews/S22-review-prompt.md` is review machinery, present in the range because
   the prompt was re-emitted during the review cycle, and is exempt from rule 4's file
   list - every implementation file is on the list. The range keeps its end at the final
   implementation/evidence state and is named in the prompt.

3. **S29 suite gate (frozen checkpoint).** Edit `scripts/checks/S29.sh` to assert the two
   suites the build plan's S29 gate names, using the established S16/S17 idiom (run the
   make target, parse the `.workflow` summary; never trust a bare exit code for
   `verify`, which returns 0 even when R-checks fail). Both run **before** the U12
   namespace deletion, because U12 destroys `voting-a`, which both suites need alive.
   Each assertion carries its own readable `FAIL:` line naming the gate. This is the one
   behaviour-changing fix; it is sanctioned here and committed with it.

4. **Design line (docs/designs).** Correct the single stale sentence in
   `docs/designs/declarers-and-consumers.md` from `scripts/checks/S22.sh` to
   `scripts/checks/S29.sh`, matching the build-plan S29 step that already records the
   mapping. This is the named exception to that file's read-only default, because with
   no next round the wrong path would otherwise persist. No other design text changes.

### The S29.sh insertion

Placed after U13 and before the U12 block, using `voting-a` (still alive at that point):

- `make verify NS=voting-a` -> parse `app/.workflow/verify.md` for
  `===== 17 PASS, 0 FAIL =====`; a mismatch fails naming `make verify`.
- `make jit-verify` -> require exit 0 and parse `.workflow/verify-jit.md` for
  `J1`-`J11` all `PASS`; a mismatch fails naming `make jit-verify`.

Both logs are appended under `docs/evidence/` by the existing Makefile targets and join
the evidence as the gate requires.

## Consequences

**Easy.** S22's prompt no longer blocks a correct implementation; the range's contents
are honestly described; S29's suite-survival gate is a command that fails readably, not
a sentence the implementer must remember; and the design no longer sends a reader to a
file that does not exist. With no next design round, all four are closed rather than
carried.

**Hard / ruled out.** `scripts/checks/S29.sh` is edited twice more than its original
freeze; every edit is enumerated here and committed with this ADR, and the S29 evidence
must be regenerated afterwards. This ADR is the last sanctioned checkpoint change before
S23 begins: any further change needs ADR 0007. The ordering debt noted in ADR 0005
(`bcedbd6`/`d0d4329`) stands as history.

**Not done here.** The review's Notes (RUNBOOK/opencode.json/rules beyond the design's
Verification section; the S28 substring-grep weakness; S23's self-reported spike
measurements) are observations, not concerns, and are not actioned - they are properties
of frozen gates or of steps not yet built. The three S29 concerns ADR 0005 already parks
(U7's `postgres_db` variant, U1's Secret bytes, U3/U13's timestamps) remain parked: this
ADR resolves the four the S22 review raised, not a redesign of the U-table.
