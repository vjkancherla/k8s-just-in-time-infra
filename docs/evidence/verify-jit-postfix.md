J1  PASS deployed into voting-a: 3 claims Ready, 3 containers on 172.19.0.101 172.19.0.102 172.19.0.100 (one block of 10)
J2  PASS 3 Secrets + Services + EndpointSlices present; R1-R17 = 17 PASS, 0 FAIL =====
J3  PASS pgAdmin HTTP 200 on :5050, registered 172.19.0.102:5432, Service jit-pgadmin port 80
J4  PASS vote deleted: postgres+pgadmin Orphaned with expiresAt, all 3 containers still running, worker still drained a vote
J5  PASS redeployed inside the window: same 3 container ids, tally 5 -> 6 (+1 marker), R4's row intact
J6  PASS after the 2m window postgres+pgadmin were swept in 224s (container, Secret, Service, EndpointSlice) while redis stayed up; postgres data volume removed
J7  PASS vote gone: redis kept Ready + referencedBy [voting-app-worker] (last-reference rule) while postgres Orphaned
J8  PASS deleted ns voting-b: its 3 containers and claims were gone in 28s with no TTL armed (hard path), voting-a's 3 claims still Ready
J9  PASS controller was down when vote was deleted; the restarted resync still marked postgres+pgadmin Orphaned and redis stayed Ready
J10 PASS runner stopped: redis+postgres Failed with a message, pgadmin '<no phase>' (pending), no container started, no pod Ready - runner restored
J11 PASS jit-state holds ns/voting-a/{redis,postgres,pgadmin}/terraform.tfstate and an ns/voting-b/ prefix, every key ns/<ns>/<module>/terraform.tfstate

===== 11 PASS, 0 FAIL =====
