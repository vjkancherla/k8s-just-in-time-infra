Updated: 2026-09-17

## Working
Nothing. The annotation realignment is committed, verified against a live cluster and
re-baselined; the host was torn down afterwards.

## Done (verified)
- addcf88, 39597af, a70f832: manifests + J-checks + six docs realigned; the demo rehearsal plan
  and the run evidence are tracked.
- Live, before the teardown: R1-R17 17 PASS; J1-J11 11 PASS, 0 FAIL. J6 swept pgadmin 155s after
  vote was deleted and left redis+postgres Ready with the postgres data volume intact.
- The annotation contract held through the real parser: legal key grammar, JSON limited to
  module/moduleVersion/params/softDeleteTTL, value.module == key suffix, `10m` -> 0:10:00,
  params checked against variables.tf, refcounts agreeing (97 checks; the script was scratch
  and went with the rest of /tmp).
- Host clean: no k3d cluster, no module containers, no volumes.
- S20 and S21: findings CLEAR at bfd996b, both boxes ticked in d7f2e41.

## Broken (confirmed by execution)
- Nothing.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data
  directory, container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks
  fail; `ipam.py` has no lock.
- moduleVersion is inert - the runner never reads the field.
- No gate covers volume removal on destroy (see activeContext's Watch out).

## In progress
Nothing.

## Blocked
- Nothing.

## Learnings
- An annotation is a provisioning request and a keep-alive lease, not a dependency list: the
  controller never reads the pod spec, so a consumer with no annotation can lose its infra.
- `make jit-verify` seds the live annotations to 2m and never restores them, so a rehearsal
  leaves the demo on a two-minute clock - re-run `make demo-up` (or click Start the demo).
- Read the read model before quoting it: `/state` runs scripts/state.sh, not console/state.py.
