# S16 Findings — Rework the six R-checks that the migration invalidates

**Reviewer:** Claude (different model, as requested)
**Commit range:** 1a4fccf → e8c2b4e
**Checkpoint:** `bash scripts/checks/S16.sh` — exit 0, all PASS lines confirmed

---

## 1. Checkpoint independence and failure diagnostics

`S16.sh` asserts three things: `make verify` wrote `17 PASS, 0 FAIL` into `.workflow/verify.md`, no StatefulSet exists, and no PVC exists. It also preconditions on the three app Deployments being Ready and the two stateful-tier containers being running.

**Can a count of PASS lines let a reworked check pass by emitting PASS without proving anything?** Yes in theory: `verify.sh`'s `pass()` function unconditionally increments PASS and writes the line, so a check that calls `pass()` before testing anything would inflate the count. In practice, every check performs its assertion before calling `pass()` or `fail()`, so the current code does not exploit this. But the gate cannot distinguish a rigorous PASS from a vacuous one — it trusts the count.

**Does the gate's failure output name the failing checks clearly?** Yes. Lines 72–74 of S16.sh `grep` for `^R[0-9]+[[:space:]]+FAIL` in `verify.md` and print up to 20 matches before the `fail()` call. This is sufficient to diagnose which R-check broke from the log alone.

**Verdict:** The checkpoint is a reasonable frozen gate for a count-based assertion. The precondition that containers exist is the real protection against misattribution.

---

## 2. The "eleven unaffected" claim — scope drift vs legitimate rework

The build plan names R2, R8, R9, R10, R11, R16, R17. R3, R4, R6 and R7 were also broken:

- R3, R4, R6 read Postgres through `psql_q()`, which called `kubectl exec "$PGPOD"` before S16 rewrote it to `docker exec`.
- R7's body itself called `kubectl exec "$PGPOD"` directly — not through the helper.

**Is changing the helpers and R7 legitimate rework or scope drift?** Legitimate rework. The helpers are the shared interface to the stateful tiers; rewriting them to `docker exec` is the mechanical consequence of the migration, not an addition. R7 needed one line changed. The four check *bodies* (R3, R4, R6) were not touched — only the helper they call. This is the same step, not scope drift.

**Is build-plan.md's "eleven unaffected" now a false statement?** Yes. Only seven checks are unaffected: R1, R5, R12, R13, R14, R15 (and R12's `sed` approach is a separate concern — see item 11). The build-plan table should be corrected, or a footnote added noting that the helpers also changed R3, R4, R6, R7. The todo.md "Review" section already records this accurately; the build-plan text is the stale one.

**Action needed:** Correct build-plan.md's S16 section. Low priority — the todo.md review section already documents the real scope.


---

## 3. The helpers: can an absent container or erroring query produce a PASS?

Both `psql_q()` and `redis_q()` redirect stderr to `/dev/null` and return the empty string on any failure (docker not running, container absent, query error, timeout). Analysis of every consumer:

| Check | Empty-string scenario | Result | Protected by S16.sh? |
|-------|-----------------------|--------|---------------------|
| R2 (`-gt`) | `before_len=""`, `after_len=""` | arithmetic error → FAIL (bash treats empty as non-numeric) | Yes — containers must be running |
| R3 (`==`) | `total1=""`, `total2=""` | `"" == ""` → **PASS** (false positive) | Yes — containers must be running |
| R4 (`== 1`) | `r4_count=""` | `"" == "1"` → FAIL | Yes |
| R6 (`-gt`) | `before_total=""`, `after_total=""` | arithmetic error → FAIL | Yes |
| R7 (grep) | `schema=""` | grep finds nothing → FAIL | Yes |
| R8 (`-gt`, `== 0`) | `before_total8=""`, `after_total8=""`, `drained=""` | arithmetic error on `-gt`; `"" == "0"` → PASS on drain (false positive if before/after both empty) | Yes |
| R9 (`-z`) | `before9=""` | `-z ""` → true → FAIL (explicit guard) | Yes |
| R16 (`== PONG`) | `redis16=""` | `"" == "PONG"` → FAIL | Yes |

**R3 is the most dangerous:** both `total1` and `total2` being empty produces a PASS. R8 has a similar risk on the drain assertion. Both are protected by S16.sh's precondition that the containers exist at test start. If a container crashed *during* the run, the protection would fail — but that is a coincidence of ordering, not a design guarantee. For this step (single namespace, containers provisioned once), it is acceptable. S17's verification script (`set -euo pipefail`) should add explicit guards.

---

## 4. R2 and R8: pause-resume semantics with out-of-cluster infra

**Is pausing the consumer still a meaningful test?** Yes. The property being tested is "votes accumulate in the queue while the worker is down and drain when it restarts." The queue (Redis) and consumer (worker) are separate processes connected over the network — pausing the consumer by scaling its Deployment to zero still makes the queue observable. The `-n "$NS"` addition is necessary because the deployment is namespace-scoped, though for `default` it is technically redundant.

**Arithmetic guards:** R2 uses `"$after_len" -gt "$before_len"`. If `redis_q` returns empty (container crash mid-test), bash's `[[ "" -gt "" ]]` with `set -u` would produce an arithmetic error, causing a FAIL — correct behavior. R8's `"$queued" -lt 1` similarly errors on empty.


---

## 5. R9: `docker restart` vs deleting the StatefulSet pod

**Does `docker restart` test the same property?** The original test deleted the StatefulSet pod, which destroyed the container and started a new one from the same PVC. `docker restart` sends SIGTERM, stops the container, and starts it again from the same image and the same named volume. Both preserve the data; `docker restart` is lighter (no pod scheduling, no PVC re-attach) but tests the same core property: the tally survives process restart because the data is on a persistent volume.

**Does it prove the named volume was used?** No — it infers it from an unchanged count. The proof is architectural: `postgres/main.tf` declares `docker_volume.postgres_data` and mounts it at `/var/lib/postgresql/data`. The test verifies the consequence, not the mechanism. Acceptable for a PoC checkpoint.

**Is the "result reconnected" loop doing anything measurable?** Lines 202–206 poll the result pod's Ready condition for up to 60 seconds. After a Postgres restart, the result container's psycopg2 connection drops; Kubernetes marks the pod Not Ready when `/healthz` fails. The loop waits for Ready=True before reading the tally, ensuring the result page is functional. Without it, `after9` could be read while result is still reconnecting, and R13/R16 would inherit the restart latency. The loop is doing real work.

---

## 6. R10 and R11: count of 3 and namespace scoping

**Is 3 the right count?** Yes. After S15, the namespace holds three Deployments: vote, worker, result. Redis and Postgres are containers outside the cluster.

**Does dropping `statefulset` remove a signal?** Yes — it removes the ability to detect an unexpected StatefulSet. However, S16.sh explicitly asserts `no StatefulSet in default` (line 80), so this signal is covered elsewhere.

**Is namespace scoping sufficient to exclude the JIT controller?** The JIT controller Deployment runs in `default` but its YAML has no liveness/readiness probes, so R10's jq pipeline excludes it. Even if it did, the count would be 4 (not 3), producing a clear FAIL. Namespace scoping plus the hardcoded count is sufficient.

---

## 7. R17: the JIT outputs Secret

**Does R17 still assert the stated property?** R17 asserts: (a) no literal `POSTGRES_PASSWORD` in the kustomize YAML, and (b) the `jit-postgres` Secret holds `POSTGRES_PASSWORD`. The source changed from `voting-app-postgres` to `jit-postgres`, but the property — credentials are in-cluster Secret material, not source-tree literals — is preserved.

**Does the source-tree grep still cover the built manifests?** The grep searches `"$KUSTOMIZE_DIR"` for `POSTGRES_PASSWORD` in YAML files. The `voting-app-secret-key` Secret holds `SECRET_KEY`, not `POSTGRES_PASSWORD`. The grep is correct.

**Does anything else carry the password in the clear?** The `jit-postgres` Secret (base64, standard k8s). The runner passes it as a param and stores it in tofu state in MinIO — both out of R17's scope. The `SECRET_KEY` literal is a Flask session key, not a database credential. R17 is correctly scoped.

---

## 8. Container-name convention and `default`-hardcoded assumptions

**Convention trace:** Controller (`main.py:307`) sets `runner_params["name"] = f"{ns}-{module}"`. Modules produce `"${var.name}-redis"` and `"${var.name}-postgres"`. verify.sh builds `${NS}-redis-redis` and `${NS}-postgres-postgres`. The convention holds for any namespace. For `voting-a`: `voting-a-redis-redis` and `voting-a-postgres-postgres`.

**Things that still assume `default`:**

| Item | Overridable? | Real defect for S17? |
|------|-------------|---------------------|
| `RELEASE="voting-app"` | Yes, via env var | **Yes** — release name differs per namespace |
| `VOTE_URL`/`RESULT_URL` | Yes, via env var | **Yes** — ingress hostnames differ |
| R14: `kubectl get svc -o json` | Not parameterised | **Yes** — cluster-wide scan counts JIT Services from other namespaces |

---

## 9. MANUAL-TESTING-GUIDE.md

The guide correctly reflects the reworked checks:
- Architecture recap (§1) correctly describes Redis and Postgres as containers on the k3d network, names the containers, and notes the `jit-postgres` Secret.
- §7 (R7–R9) commands use `docker exec default-postgres-postgres` — correct.
- §8 (R10–R17) commands use the right container names and `jit-postgres` Secret.
- The guide does not claim anything about pgAdmin, the JIT stack, or the destroy path — correct for this step.

**One observation:** `app/docs/SCRIPTS-GUIDE.md` line 48 still says "postgres: stores the `votes` table (1Gi PVC). StatefulSet → stable pod name `voting-app-postgres-0`." This was not in S16's scope but will mislead a reader. Flag for S17.

---

## 10. Lessons and flags

**Lessons.md — two new entries:**
1. "Grep for the shared helper, not the requirement number." Correctly characterised. The build-plan inventory was incomplete.
2. "A stale gate that passes is more dangerous than one that fails." Correctly characterised. `S00.sh`'s latent passing was exactly this failure mode.

**todo.md — two S17 flags:**
1. The 6379 finding: `int(outputs.get("port", "6379"))` gives pgadmin redis's port. Correctly characterised and deferred.
2. `S00.sh` now fails honestly. Header documents the staleness. Re-opening was rejected in S15 findings.

**Is a permanently failing frozen gate acceptable?** Yes, with the caveat that S17 must decide: retire it or re-open it. Carrying a known-failing gate indefinitely erodes trust in the checkpoint suite.

---

## 11. R1, R5, R12–R15 unchanged; R12's `sed` approach

**R1** (vote page): Untouched. HTTP check, no stateful-tier dependency.
**R5** (result page): Untouched. Reads from the result page, not Postgres directly.
**R12** (kustomize builds): Untouched. `sed`s the registry hostname into the base; does not read stateful tiers.
**R13** (HTTPS reachability): Untouched.
**R14** (no NodePort): Untouched.
**R15** (arm64 images): Untouched.

**Should reworking the stateful-tier checks have caught R12's `sed` approach?** No. R12 does not interact with the stateful tiers. The `sed` approach is a separate concern (flagged in S15 findings: "test an overlay by building it, not by describing it").

**Does replacing the Stage A app invalidate anything else?** `app/README.md` and `app/docs/SCRIPTS-GUIDE.md` still describe the pre-migration topology in places. Both need updating — flag for S17. Checkpoints S01–S14 test earlier infrastructure stages and are unaffected. S00 is already flagged.

---

## 12. Checkpoint coverage gaps

`S16.sh` cannot observe:
1. **Behaviour outside `default`:** Not applicable — S16 only runs in `default`.
2. **The pgAdmin path:** No R-check touches pgAdmin. Correct for this step.
3. **The destroy path:** Not tested by `make verify`. Correct for this step.
4. **R2/R8 pause-resume mechanics:** The checkpoint asserts the count, not that the pause-resume cycle actually worked.
5. **R9 restart mechanics:** The checkpoint asserts the count, not that the restart preserved the tally.
6. **R14/R15 cluster-wide scope:** The checkpoint asserts the count, not that the scope is correct.

Items 1–3 are out of this step's design. Items 4–5 are the cost of a count-based gate. Item 6 is pre-existing. The checkpoint has run three times with exit 0. This is sufficient evidence for the assertions it makes.

---

## Verdict

### CONCERNS — resolved in `3cdd4b6`

The code rework is correct and the checkpoint passes. Two concerns were raised and both fixed:

1. **~~The helpers' silent-empty pattern~~** (item 3): **Fixed.** R2, R3, R6 and R8 now assert their reads are non-empty before comparing, naming the container in the failure message. R4, R7 and R16 compare against literals and fail on their own. R8's worker-restore (`scale --replicas=1`) now runs on every path, not just the happy drain branch — an early `fail` would otherwise leave the app with no consumer for the rest of the run.

2. **~~build-plan.md's "eleven unaffected" is stale~~** (item 2): **Fixed.** A dated correction is in place: the table lists seven rows, the shared helpers also invalidated R3, R4, R6 and R7, and eleven of seventeen checks were invalidated in total. Six were genuinely unaffected.

**Verdict: CLEAR**

Both concerns addressed in the same step. No new issues. S17 may proceed.

