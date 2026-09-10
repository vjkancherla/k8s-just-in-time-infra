Updated: 2026-10-09

## Current focus
S15 (migrate the voting app onto JIT infra) is blocked on one design question: S15's
frozen gate asserts `kubectl kustomize app/kustomize/overlays/registry` builds — it does not.

## Done (verified this pass)
- S-1 gap found: only S00-S14 existed, so S15 had no frozen gate. Wrote
  scripts/checks/S15.sh, S16.sh, S17.sh from build-plan.md; committed c2e01a0.
- All three run to exit 1 with readable FAIL lines and zero syntax errors (`bash -n` clean).
- `kubectl kustomize app/kustomize` builds (479 lines). `kubectl kustomize
  app/kustomize/overlays/registry` fails: cycle detected — `resources: - ../..`
  nests the overlay inside the base's own tree.
- R12 does not build the overlay; it seds the registry hostname into the base, so
  the breakage is invisible to `make verify`.

## Checkpoints (final code)
- PASS: S13 IPAM (/tmp/s13-b.log) · PASS: S14 real provisioning (/tmp/s14-backend.log)
- S15/S16/S17 fail cleanly by design (they gate unimplemented work) — the S-1 requirement.

## Commits
c2e01a0 S-1 checks S15-S17 · 1b50388 S14 review prompt · bed3dc0 remote-state backend ·
b2e7c57 memory bank · 020f899 IPAM + postgres

## Next step
Answer the registry-overlay question, then implement S15.

## Watch out
- scripts/checks/S00-S07.sh are UNTRACKED in git — S-1's "frozen" files are not committed.
- S-1 also owed scripts/checks/run-all.sh and scripts/review-guard.sh; neither exists.
- S13.sh's `kubectl set env` leaves the controller mutated — re-apply deploy/controller.yaml
  before running S14.
- Conflicting-params scenario still UNVERIFIED (S14 findings).
