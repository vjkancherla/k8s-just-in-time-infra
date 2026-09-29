# Active Context

Updated: 2026-09-29 (HANDOFF debt session, follow-up to the Stage-H accept)

## Current focus

The `docs/HANDOFF.md` debt list is worked through: P0.1-P0.5 done, and the runner /
controller / S25 parts of P0.6 accepted; P1 S18 corrected. The human directed "stop the
bleed" (the per-step implement+checkpoint+review loop was costing an hour+), so the
remaining low-value tail is explicitly deferred: S26 coverage gaps + ADR 0012's false
unit-test claim, S27's `service_url` helpers, and one cumulative review of the session.

## Done (verified, on `main` since `a374e21`)

- **P0.1** `delete_run` holds `_run_lock(key)` for the whole resolve+destroy (`f8bf679`;
  review `docs/reviews/runner-delete-run-lock-findings.md`).
- **P0.2** runner debt: a failed `state list` refuses; segment-aware `postgresql_` filter;
  logged cleanup (`_rmtree`); `CancelledError` cleanup (`6105ce2`, review
  `runner-r1-robustness-findings.md`); then `runner-api.md` refreshed, startup sweep of
  orphan work dirs, ADR 0023 debt-1 annotated, plus R1 concerns 2-3 (`d917804`, review
  `runner-r2-ops-review-findings.md`).
- **P0.3** controller: `_merge_patch` clears nested `appliedParams`/`spec.params` keys;
  params validated on the create path too (ADR 0025; `b4e7a7c`/`a0b1f95`; review
  `controller-c1-review-findings.md`).
- **P0.4** gate: `S29.sh` U13's postgres half now asserts `voting-b-postgres` TTL = 10m
  (ADR 0026); full S29 gate green on a clean tree (`docs/evidence/S29.log`, pending 0).
- **P0.5** design prose: postgres `Databases` bullet is `setsubtract` (ADR 0016); the
  deleted overnight transcript is marked removed (`08ec92c`).
- **P0.6 (S25)** `_CONDITION_TYPES` guard + S25 restores its status probe, so no residue
  (ADR 0027; `9bffd7e`).
- **P1 (S18)** the post-undeploy redis assertion now expects `Orphaned`, not `Ready`
  (ADR 0028; `e1e2006`).
- All reviews were `CONCERNS` with empty Blockers (accepted under ADR 0023's bar).
- **Ponytail audit** of the session diff flagged four deferrable additions: the startup
  sweep (a `docker run --tmpfs /tmp` native fix), the `_CONDITION_TYPES` guard, the
  module-qualified regex, and arguably the create-path validation. Not backed out.

## Checkpoints

- Live this session, each on the tree current at the time: S24 and S27 (`d917804`), S26
  (`a0b1f95`), the S29 gate (`e1191ea`, clean tree), S25 (`017bce0`). Only S25 ran after the
  final controller commit `9bffd7e`; the others ran before it. The cumulative review
  (`docs/reviews/session-debt-cumulative-findings.md`) notes S26/S29 never saw the final
  controller code (the `_CONDITION_TYPES` guard is inert, so the risk is low).
- S18 was amended but **not re-run** (needs `make demo-up`; the stack had no tenants after
  the gate).

## Next step

- `make test-up` before any demo or gate - the S29 U12 namespace delete left no tenants.
- Deferred tail (S26/S27) or a cumulative review, at the human's call.

## Watch out

- **16 commits on `main` since `a374e21`** (`f8bf679..e1e2006`), tree clean but
  `docs/HANDOFF.md` untracked.
- **Ponytail is installed and always-on** for interactive sessions; `run-overnight.sh`
  exports `PONYTAIL_DEFAULT_MODE=off` so the overnight agents are unaffected.
- **New ADRs 0025-0028; two amend frozen checkpoints** (S25 by 0027, S29 by 0026) and one
  retires a stale assertion (S18 by 0028). Each committed with its edit.
- The reviewed-but-accepted concerns are debt, not fixed: runner-r2 concern 1 (the
  `state list` phrase test fails open), controller-c1 concern 1 (S26 gates neither C1
  fix), and the general "no checkpoint asserts these debt fixes" theme.
- **S18's correction is unconfirmed live.** Its evidence is deferred by the speed decision.
- Carried truths: existing namespaces may hold Secrets without the new keys (redeploy
  needs a Secret patch or a namespace recreate); `app/*/Dockerfile` COPYs templates, so a
  template edit needs a rebuild; `console/serve.py` writes
  `docs/evidence/console-<name>.log` and the browser suite redirects `serve.EVIDENCE` (keep
  the swap); pgadmin's lease on `vote` is deliberate; `refs/cline/checkpoints/*` snapshot
  `.env` and `terraform.tfstate` (never `git push --all`/`--mirror`); the CRD `status`
  schema is a closed list.
