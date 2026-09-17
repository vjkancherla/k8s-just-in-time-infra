Updated: 2026-09-17

## Working
Stage G's gate is met, the docs it owed are written, the build-plan Done list is closed with nine boxes
explained in docs/todo.md, and there is now a standalone visual explainer for the controller.

## Done (verified)
- Three self-contained docs/*.html pages, each driven in headless Chrome rather than eyeballed:
  controller-explained (14 slides), deletion-lifecycle (clock simulator + guard toggle) and
  annotation-to-state (resolves all 6 namespace-module combinations against the rendered DOM); README links
  all three.
- The "admissions controller" question: none exists here (no webhook, no ValidatingWebhookConfiguration, no
  ValidatingAdmissionPolicy). The nearest component is the kopf reconciler, jit-controller/main.py.
- S20 and S21: findings CLEAR at bfd996b, both boxes ticked in d7f2e41.
- Gate after a cold `make demo-up` ("17 PASS, 0 FAIL"): `make check STEP=18` gave 12 ok lines, PASS, exit 0.
- docs/todo.md's Review section carries S18-S21; docs/lessons.md has the Stage G section.
- `make timeline` against a real run: 36 events, five lanes, all thirteen kinds (2eb5073).

## Broken (confirmed by execution)
- Nothing.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data directory,
  container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks fail; `ipam.py` has no lock.
- docs/deletion-lifecycle.md says the demo window is 2m; the manifests deploy 10m and verify-jit.sh forces 2m.

## In progress
Nothing.

## Blocked
- Nothing. S22 (live lanes) is unwritten future work, not a blocker.

## Learnings
- A reviewed range must end BEFORE its step's tracker tick, so the tick is deliberately the first commit after
  the last reviewed SHA; a retro-checkpoint's record commit IS the reviewed diff and must not touch it either.
- A checkpoint that asserts against live state cannot be re-run green on a stopped host: S18 fails on its own
  precondition until `make demo-up` has run.
- "Admission controller" appears nowhere in this repo - grep for the term before explaining a component.
