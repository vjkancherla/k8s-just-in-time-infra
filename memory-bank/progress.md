Updated: 2026-09-10

## Working
S17 is complete: the two-namespace demo, `make jit-verify` J1-J11 and `make verify` in voting-a all
green in one `bash scripts/checks/S17.sh` run, and the duplicate-IP race fixed with repeat evidence
rather than a single lucky run.

## Done (verified)
- S0-S16: checkpoints pass and are committed. S00 fails by design (pre-migration assertions).
- J1: voting-a deploys 3 claims Ready and 3 containers on three distinct IPs from one block of 10 -
  `.100/.101/.102` in both complete suite runs, and 3/3 in the race test that repeats it 3x.
- J2: R1-R17 = 17 PASS, 0 FAIL in voting-a; 3 Secrets + Services + EndpointSlices.
- J3: pgAdmin HTTP 200 on :5050, `/pgadmin4/servers.json` registers `<postgres-ip>:5432`, Service
  `jit-pgadmin` port 80.
- J4/J5: deleting `vote` orphans postgres+pgadmin with `expiresAt` and keeps all 3 containers
  running; the worker still drains a vote; redeploying inside the window reuses the container ids
  and the tally survives.
- J6: past the 2m window the sweep removes the containers, Secrets, Services, EndpointSlices and the
  postgres data volume, while redis stays up.
- J8: `kubectl delete ns voting-b` removes 3 containers and their claims in ~30s, no TTL armed,
  voting-a untouched.
- J9: controller killed, `vote` deleted, controller restarted - the resync still marks
  postgres+pgadmin Orphaned and keeps redis Ready.
- J10: with the runner stopped, redis+postgres go Failed with a readable message, pgadmin has no
  phase, no container starts and no pod becomes Ready.
- J11: `ns/voting-a/{redis,postgres,pgadmin}/terraform.tfstate` plus an `ns/voting-b/` prefix, and
  every key matches `ns/<ns>/<module>/terraform.tfstate`.

## In progress
Nothing - the next action is the S17 review, not another implementation step.

## Blocked
- S17's `review` box: only a different model's `CLEAR` in `docs/reviews/S17-findings.md` ticks it.

## Learnings
- The duplicate IP had two causes: allocation locked per claim instead of per namespace, and a double
  `release_block` (the ledger's `count: 2` against 3 live claims, not arithmetic noise).
- A green suite run does not prove a race is fixed; a repeat test does.
- A check that has never executed is not a passing check - J11 hid both a 403 and a missing PASS.
- Assert the PASS line, not the exit code: both failing runs exited 0.