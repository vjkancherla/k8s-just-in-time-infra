Updated: 2026-09-17

## Working
Nothing - the annotation realignment is complete, verified against a live cluster and
re-baselined. The work is uncommitted.

## Done (verified)
- Annotations aligned to their consumers (vote redis+pgadmin, worker redis+postgres, result
  postgres) and the suite re-baselined: R1-R17 17 PASS; J1-J11 11 PASS, 0 FAIL.
- J4/J6/J7/J9 rewritten for the new refcounts. J6's live result: pgadmin swept 155s after vote
  was deleted, redis+postgres stayed Ready, the postgres data volume remained - the old split
  could not make that assertion at all.
- The annotation contract holds through the real parser: legal key grammar, JSON limited to
  module/moduleVersion/params/softDeleteTTL, value.module == key suffix, `10m` -> 0:10:00,
  every required variables.tf input injected. 97/97 in /tmp/verify_jit_annotations.py.
- Six docs realigned; S15-findings.md amended with a dated note rather than rewritten.
- S20 and S21: findings CLEAR at bfd996b, both boxes ticked in d7f2e41.

## Broken (confirmed by execution)
- Nothing.

## Suspected (read, not reproduced)
- The three carried from 2026-09-13 stand: postgres's password can disagree across its data
  directory, container and Secret; `app/scripts/verify.sh` returns 0 however many R-checks
  fail; `ipam.py` has no lock.
- moduleVersion is inert - the runner never reads the field.

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
