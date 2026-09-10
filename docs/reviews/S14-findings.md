# S14 Findings

**Reviewer:** Gemini 2.5 Pro (re-review, commit range 9184a7b -> bed3dc0)
**Date:** 2026-10-09
**Verdict:** CLEAR (with one unverified item)

---

## 1. Build-plan S14 goal

Goal: "real containers, driven by the controller."

Reviewed. The diff delivers:
- Controller calls the runner via RUNNER_URL/v1/runs with a bearer token from jit-runner-token Secret.
- On success: outputs Secret, Service (no selector, clusterIP=None), EndpointSlice at status.allocatedIP.
- On failure: phase Failed, message = runner error (capped at 512 chars), no retry (resync skips Failed until a Deployment change re-fires handle_deployment).
- Conflicting params: check_param_conflict sets a ParamsConflict condition when 2+ Deployments disagree on params (first-writer-wins semantics). However, no checkpoint phase covers this. See item 9.

**PASS.**

---

## 2. provision_infra

- call_runner POSTs to RUNNER_URL/v1/runs with Authorization: Bearer $RUNNER_TOKEN from controller.yaml's secretKeyRef.
- Runner params are annotation params + mandatory name, ip, network overrides (lines 258-261).
- Success path: runner_resp["status"] == "success" -> _write_k8s_resources creates Secret (create-or-patch), Service, EndpointSlice, sets phase Ready and clears expiresAt.
- Failure path: sets phase Failed with runner_resp["error"] truncated to 512 chars, then returns. Resync at line 690 skips Failed until the next Deployment event. No retry storm.
- RUNNER_URL="" fall-through: _provision_fake creates a Secret with a non-empty marker key and sets Ready. Preserves S8-S12 compat.

**PASS.**

---

## 3. destroy_infra

- RUNNER_URL unset -> returns True (safe no-op, same semantics as S8-S12).
- Params: extra module params first (from spec.params), then name, network, ip as mandatory overrides (lines 578-582). The comment correctly explains why: "a stale annotation cannot redirect the destroy at the wrong container."
- Cold state: resync_referenced_by re-reads the spec fresh from the API server (line 669-673), then passes spec.get("params", {}) to destroy_infra. For postgres, this means the password is available for the runner's tofu init.
- Response parsing: r.status_code == 200 AND result["status"] in ("destroyed", "not_found") -> success. The comment at lines 594-596 explains why: the runner returns HTTP 200 for logical failures.
- 404 from the runner (no in-memory run) is also treated as success -- the container is gone.

**PASS.**

---

## 4. Clusterwide watch

WATCH_NAMESPACES="" -> namespaces list is empty -> kopf.run(clusterwide=True). When set, kopf.run(namespaces=...). No code path assumes a fixed namespace list. controller.yaml sets WATCH_NAMESPACES: "".

**PASS.**

---

## 5. Stale-Ready handling

provision_infra lines 219-247:

- Claim Ready but Secret missing (404) or empty -> logs stale detection, patches phase to "" and expiresAt to None, re-reads the claim, falls through to the runner call.
- After re-provisioning, the claim returns to Ready with a fresh Secret. The next handler invocation sees Ready + Secret with data -> early return. No loop.
- The resync timer calling provision_infra on the same claim: claim_lock serialises; if the claim is already Ready with a Secret, the guard at line 224 returns immediately. No fight.
- Clearing expiresAt during stale recovery is defensive -- prevents a TTL sweep from firing on a claim that is being actively re-provisioned. Correct.

**PASS.**

---

## 6. list_referencing_deployments and fresh status read

list_referencing_deployments uses AppsV1Api.list_namespaced_deployment(namespace) -- the standard k8s Python client. The earlier raw-HTTP workaround has been correctly reverted.

Fresh status read (lines 669-680): api.get_namespaced_custom_object_status() is genuinely needed because kopf's timer body can lag behind status patches the controller itself made within the same timer cycle. The broad except Exception is justified -- urllib3.MaxRetryError is not an ApiException -- and the fallback to the handler body is logged. The comment explains the trade-off clearly.

**PASS.**

---

## 7. S14.sh checkpoint phases

- **Phase 1:** Annotate -> waits for Ready AND Secret with data (lines 103-116). Asserts: Secret exists with data, Service exists, EndpointSlice address matches allocatedIP, container running at the correct IP.
- **Phase 2:** Creates a Job that resolves jit-redis via the Service DNS name and issues PING. Asserts PONG in the Job's logs.
- **Phase 3:** Stops the runner (docker stop jit-runner), creates a second Deployment. Asserts: claim Failed with a readable status.message, pod is held back by the missing JIT Secret (waiting reason).
- **Phase 4:** Full S10 soft-delete lifecycle with real containers: Ready -> delete -> Orphaned with expiresAt and Secret alive -> resurrect (same Secret UID, expiresAt cleared) -> delete again -> TTL sweep. The sweep uses a restarted runner (line 422) so the destroy is cold (no in-memory cache). Asserts: claim gone, Secret gone, container gone from docker ps -a.

**PASS.**

---

## 8. Checkpoint fix: -n flag on kubectl delete

Step 2 and Step 4 previously ran kubectl delete deployment "$DEPLOY_NAME" without -n "$NAMESPACE", which targeted namespace default instead of s14-test. The s14-deploy Deployment in s14-test was never deleted, so referencedBy always contained it, and the claim could never leave Ready.

**The fix is legitimate.** It corrects a real bug in the checkpoint that masked the controller's behaviour. The controller workaround (fresh status read + broad exception handling) was correct independently -- it addresses kopf body staleness, not the checkpoint bug. The workaround is now defensive rather than essential; keeping it is reasonable given the low cost.

**PASS.**

---

## 9. Conflicting params between two Deployments -- UNVERIFIED

S14's build-plan entry requires: "Conflicting params between two Deployments: first writer wins, warning condition naming both."

The controller code for this exists at check_param_conflict (lines 516-548): when len(refs) >= 2 and a Deployment's annotation params differ from the stored claim params, it sets a ParamsConflict condition naming both the winner and the ignored writer.

**However, no checkpoint phase covers this scenario.** All four S14.sh phases use the same annotation params ({} or the same ANNOTATION variable), so check_param_conflict never fires. There is no reviewer-visible evidence that first-writer-wins with a warning actually works.

**Treat as UNVERIFIED.** The code is plausible and the logic reads correctly, but it has not been exercised by the checkpoint or any unit test.

---

## 10. Defect (a): IP per-claim addressing + claim-count fix

**Before:** allocate_block ran on every ensure_claim call (every Deployment create/update event). The count grew monotonically -- one namespace had reached 193 -- so release_block never reached zero and the block was never freed. Additionally, every claim in a namespace received the same base_ip as its allocatedIP.

**Fix:** Lines 185-186: if not allocated_ip: -- allocate_block only runs for claims that have no address. first_free_address gives each claim its own address from the block.

**Count semantics against release_block:**
- allocate_block increments count only for claims without an address (once per claim).
- release_block decrements count by 1; frees the block when count hits 0.
- The lifecycle test test_two_claims_one_namespace verifies count 1 -> 2 -> 1 -> freed.
- test_release_block_removes_at_zero verifies count 2 -> 1 (block stays) and count 1 -> 0 (block freed).

**27/27 IPAM tests pass.**

**PASS.**

---

## 11. Defect (b): postgres sensitive = true

output "url" in postgres/outputs.tf now has sensitive = true. Without it, tofu apply failed because the output referenced var.postgres_password (declared sensitive = true). The redis module's output "url" does not need it (no sensitive inputs).

**PASS.**

---

## 12. Defect (c): Remote state backend + cold destroy assertions

**Before:** No module declared backend "s3" {}, so the runner's -backend-config arguments were ignored. Tofu ran on local state in a throwaway work dir. A cold destroy (runner restarted, no in-memory cache) had no state to read, so tofu destroy reported success having destroyed nothing.

**Fix:** All three modules now declare backend "s3" {}. The runner passes the full backend-config at tofu init time (lines 317-325 of jit-runner/main.py).

**Assertions are not vacuous:**
- S14.sh Phase 4 restarts the runner (line 422), waits for its health endpoint, then lets the TTL sweep fire.
- The runner's in-memory _runs dict is empty after restart, so the destroy takes the cold path: creates a temp work dir, copies the module, runs tofu init -backend-config ... to pull state from MinIO, then tofu destroy.
- Lines 443-446 assert the container is gone from docker ps -a. This is the exact failure mode that was masked before -- the container surviving a "successful" destroy.

**Regression protection:**
- Removing backend "s3" {} from a module would cause the cold destroy to operate on local state again. The Phase 4 container-gone assertion catches this.
- IPAM count: allocate_block only increments for claims with no address; test coverage exists.
- postgres sensitive: removing it makes tofu apply fail immediately.

**PASS.**

---

## Summary

| Item | Verdict |
|---|---|
| 1. Build-plan S14 | PASS |
| 2. provision_infra | PASS |
| 3. destroy_infra | PASS |
| 4. Clusterwide watch | PASS |
| 5. Stale-Ready handling | PASS |
| 6. list_referencing_deployments + fresh status read | PASS |
| 7. S14.sh checkpoint phases | PASS |
| 8. Checkpoint -n fix legitimacy | PASS |
| 9. Conflicting params (first-writer-wins) | **UNVERIFIED** |
| 10. Defect (a): IP per-claim + count fix | PASS |
| 11. Defect (b): postgres sensitive = true | PASS |
| 12. Defect (c): Remote backend + cold destroy | PASS |

**Overall: CLEAR**

The one unverified item (conflicting params) is a checkpoint gap, not a code defect. The controller logic is present and reads correctly. If coverage is desired, a Phase 5 in S14.sh could: annotate a second Deployment with different params, wait for a resync tick, assert ParamsConflict condition appears with both names, then delete the second Deployment and assert the condition is cleared.
