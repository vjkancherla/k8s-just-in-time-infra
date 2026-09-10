Updated: 2026-09-10

## Current focus
S14 — blockers fixed and all 10 review concerns acted on. Checkpoint re-run PASS.
Two NEW defects found by the multi-module probe; awaiting a decision.

## Current work
Concerns from docs/reviews/S14-findings.md, all acted on (human said proceed):
- 1 Failed is terminal (resync skips; a Deployment change retries)
- 2 controller per-claim lock + runner per-(workspace,module) asyncio lock — 1 apply, 0
  "container already in use" with 2 writers on 1 claim
- 3 `status.message` cleared on success; 4 params persist (earlier); 5 Phase 3 gates the pod
  on the JIT Secret (`CreateContainerConfigError`); 6 Phase 2 pings the Service name
- 7 destroy sends the claim's params (`vars=['ip','maxmemory','name','network']`)
- 8 runner `_runs` keyed by (workspace, module) — a second module applies itself
- 9 fake mode writes a marker key so the stale-Ready detector stops looping
- 10 resync fallback catches transport errors and logs it
- handle_claim_delete keeps S11 semantics but logs ERROR when destroy fails
Deployed: runner image rebuilt + container recreated, ConfigMap refreshed, pod restarted.
Checkpoint: `PASS: S14 real provisioning verified`, 0 FAIL (/tmp/s14-final.log).

## New findings (raised, NOT fixed)
- IPAM: every claim in a namespace gets the SAME allocatedIP (allocate_block returns the
  block base for all claims). Two modules in one namespace collide — blocks S15.
- The postgres module cannot be applied at all — `output "url"` needs `sensitive = true`, so
  `tofu apply failed`. CONCERN 7's cold-destroy path is therefore untestable end to end
  (the redis plumbing is verified).
- Fixed while here: deploy/runner.sh had 3 bugs (wrong SCRIPT_DIR; `set -e` aborting on a
  missing .env key; `docker inspect` matching the image so `up` never started).

## Next step
Human decision on the two new findings, then re-review the new commit. Do not start S15.
