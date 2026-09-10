Updated: 2026-09-10

## Current focus
S14 review returned BLOCKED (B1, B2). Both blockers are fixed and verified live; checkpoint
re-run PASS. Awaiting re-review — nothing ticked.

## Current work
Fixes only; CONCERNS 1-10 left untouched and raised with the human, per the review protocol.

## What changed this session
- **B1** — `destroy_infra` reads the response body: success only for status in
  ("destroyed", "not_found"). Live: a bogus-module destroy now logs `Destroy reported failure
  for s14-b1-probe/bogus: {'status': 'error', …}` where the old code logged the 200 as success.
- **B2** — new `check_param_conflict` in the resync sets a `ParamsConflict` condition (reason
  `FirstWriterWins`) naming the winner and the ignored writer, and clears it when resolved.
  First writer still wins: `ensure_claim` never overwrites spec and `provision_infra` returns
  early on Ready. CRD gains `status.conditions`.
- **B2 prerequisite** — `spec.params` had to persist so the winner's params are readable:
  applied the reviewer's CONCERN 4 remedy using `x-kubernetes-preserve-unknown-fields`
  (not `additionalProperties: {type: string}`, so non-string params are not pruned).
- Re-ran `bash scripts/checks/S14.sh`: PASS, 0 FAIL lines (`/tmp/s14-rerun.log`). That also
  proves the destroy success path still returns True — Step 4's TTL sweep depends on it.

## Verified live
- Two writers, different params → condition `conflict-a won with params {'maxmemory': '128mb'};
  ignored: conflict-b wants {'maxmemory': '512mb'}`; `spec.params` kept the winner's;
  container ran the winner's args; condition cleared after conflict-b was deleted
- Probes cleaned; runner up; controller 1/1

## Next step
A different model re-reviews: rewrites `docs/reviews/S14-findings.md` against these fixes.
Do not start S15.

## Open questions raised (not acted on)
- `handle_claim_delete` still ignores `destroy_infra`'s result; respecting a failure would
  block namespace deletion (S11 semantics) — needs a decision
- CONCERNS 5/6 are checkpoint-evidence gaps (`pause:3.5` gone; Phase 2 uses the IP, not the
  Service name); closing them means editing the gate, which the build plan forbids mid-step
- CONCERN 7 (destroy params for postgres/pgadmin) and CONCERN 8 (runner `_runs` keyed by
  workspace only) are S15 hazards
