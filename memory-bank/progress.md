Updated: 2026-09-26

## Working
Nothing - S22 design is complete, awaiting green light to implement.

## Done (verified)
- S1-S21 complete (docs/todo.md all checked): demo-mode automation, console read model, and timeline are live.
- S22 design complete: `docs/design/infra-change-flow-brainstorm.md` (decision + 6 acceptance criteria) and `docs/design/infra-change-flow-transcript.md` (full debate).
- Consilium on the design: 1 blocker fixed (falsifiable acceptance criteria - every give-up sets a condition within one 30s resync tick); 2 risks recorded in the brainstorm's Open questions.

## Broken (confirmed by execution)
- scripts/checks/S18.sh:147 - "redis did not stay Ready - worker still references it" cannot pass while undeploy removes all three Deployments. The check is frozen, so amending it needs the human's approval.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data directory, container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks fail; `ipam.py` has no lock.
- No gate covers volume removal on destroy any more: J6 asserts the volume stays.

## In progress
Nothing.

## Blocked
- The S18 redis assertion (see Broken) - awaiting the human.

## Learnings
- CSS text-transform reaches Playwright's inner_text: assert on the rendered casing.
- The CRD status schema is a closed list: a new status field (e.g. `paramSource`) needs a CRD edit or the API server prunes it.
- Runner `POST /v1/runs` is create-or-update with MinIO-backed state: settings changes can re-apply without a new endpoint (S22's foundation).
- A 600s runner call inside a kopf handler blocks other events; the 30s resync is the backstop.
- The referrer map is the demo: removing all three Deployments arms every TTL clock at once.
