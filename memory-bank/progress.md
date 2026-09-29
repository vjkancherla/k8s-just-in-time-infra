# Progress

Updated: 2026-09-29 (HANDOFF debt session)

## Working

Nothing is being built. The HANDOFF debt list is cleared through P0.5 and the
runner/controller/S25 parts of P0.6, plus P1 S18; the low-value tail (S26 coverage gaps,
S27 `service_url`, cumulative review) is deferred by the human's "stop the bleed" call.

## Done (verified, on `main` since `a374e21`)

- `delete_run` locked (`f8bf679`); runner robustness (`6105ce2`); runner ops/docs + sweep
  (`d917804`); controller create-validation + nested clear (ADR 0025, `b4e7a7c`/`a0b1f95`).
- `S29.sh` U13 both halves assert the TTL maximum (ADR 0026); the gate passes on a clean
  tree (`docs/evidence/S29.log`, pending 0).
- Design prose `:170` is `setsubtract` (ADR 0016); deleted-transcript refs fixed.
- `S25.sh` restores its probe and couples the controller's condition list to the CRD
  (ADR 0027).
- `S18.sh` post-undeploy redis assertion now expects `Orphaned` (ADR 0028).
- Four different-model reviews, all `CONCERNS` with empty Blockers.
- Ponytail audit of the diff named four deferrable additions (sweep, condition guard,
  module-qualified regex, create validation).

## Broken (confirmed by execution)

- None known. All live checkpoints run this session passed (S24, S25, S26, S27, S29).

## Corrected but unconfirmed

- **S18 (ADR 0028).** The amendment is committed but was not re-run for evidence: S18 needs
  `make demo-up`, and the stack had no tenants after the S29 gate. The next live S18 run is
  the confirmation.

## Suspected (read, not reproduced)

- The three carried from 2026-09-13 stand: postgres's password can disagree across its data
  directory, container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks
  fail; `ipam.py` has no lock.
- Still deferred: S26's coverage gaps (new-declarer-after-a-gap, simultaneous disagreeing
  declarers, the "consumer adds agreeing params" half) and ADR 0012's false claim that unit
  tests cover them; S27's double-produced `service_url`, unencoded `service_url_<db>`, and
  `_flatten_outputs_json`'s magic `service_urls` collision.

## Blocked

- Nothing hard-blocked.

## Learnings

- **The code fixes were trivial; the process was the cost.** Each debt item is a handful of
  lines, but the repo's per-step apparatus (image rebuild, live checkpoint, an independent
  model that re-runs the checkpoint and explores the tree, an ADR per frozen-checkpoint
  edit) is minutes-to-tens-of-minutes each. A ~20-item list therefore does not fit an hour.
- **A literal "do everything" reading was wrong.** Several handoff items are latent
  design/coverage debt, not defects. A lazy pass (the concrete defects only) is ~40 lines;
  the recommendation to defer the speculative half came only after the ponytail audit,
  which should have run first.
- **The reviewer's independent run is the expensive part.** S26 ~5-8 min, S27 ~3 min, the
  S29 gate 20+ min, and a broad-exploration review can exceed a 30-min tool timeout (one
  did, wasting the run). Bound the prompt and the reviewer's scope.
- **Frozen-checkpoint edits need their ADR committed first** - `checkpoint.sh` refuses an
  uncommitted check, so the amendment commit precedes the evidence commit.
- **A gate half that cannot fail asserts nothing** (U13's `|| true`); the fix is one
  assertion, and it caught the rule-7 per-claim scoping.
