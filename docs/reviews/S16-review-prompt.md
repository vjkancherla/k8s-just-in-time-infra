# S16 Review Prompt

**Step:** S16
**Goal:** `make verify` reports 17 PASS again, testing the same properties against
out-of-cluster infra.

**Commit range:** 1a4fccf → e8c2b4e (the R-check rework)

**Files changed:**
- app/scripts/verify.sh (reworked; see note 1)
- app/docs/MANUAL-TESTING-GUIDE.md (commands and counts aligned with the reworked checks)
- docs/lessons.md, docs/todo.md (two new lessons, the checkpoint record, the filled-in Review
  section)
- memory-bank/activeContext.md, memory-bank/progress.md

**Note on the range:** `app/scripts/verify.sh` and `app/docs/MANUAL-TESTING-GUIDE.md` were never
committed, so both land as additions and there is no diff against the pre-S16 version — read the
file, not a delta. `scripts/checks/S16.sh` arrived earlier, in c2e01a0, and is a **frozen** gate:
judge it, do not expect it to have changed.

**Checkpoint to run:** `bash scripts/checks/S16.sh`

**Instructions:**
1. Read docs/build-plan.md S16 and docs/todo.md. `scripts/checks/S16.sh` asserts only that
   `make verify` wrote `17 PASS, 0 FAIL` into `app/.workflow/verify.md`, that no StatefulSet or PVC
   exists, and that the three Deployments and two containers are present. Judge whether that is
   independent of the implementation it gates: does a count of PASS lines let a reworked check pass
   by emitting a PASS without proving anything, and does the gate's failure output name the failing
   checks clearly enough to diagnose from the log alone?
2. S16's own text says "Eleven checks are unaffected. These six are not" and lists R2, R8, R9, R10,
   R11, R16, R17. R3, R4, R6 and R7 were also broken: they read the stateful tiers through the
   shared `psql_q` / `redis_q` helpers, and R7 called `kubectl exec "$PGPOD"` directly. Judge whether
   changing the helpers and R7 is legitimate rework of the same step or scope drift beyond it, and
   whether build-plan.md's "eleven unaffected" is now a false statement that should be corrected
   rather than left.
3. Review the two helpers as the load-bearing change. Both swallow stderr and return the empty
   string on any failure. For each check that consumes them — R3 (`total1 == total2`), R4's row
   count, R6, R7's schema grep, R8's before/after totals, R16's `PONG` — say whether an absent
   container or an erroring query can produce a PASS, and whether `S16.sh`'s precondition that the
   containers exist is sufficient protection or merely a coincidence of ordering.
4. R2 and R8 still scale the `voting-app-worker` Deployment to zero to observe the queue, now with
   `-n "$NS"` added. Is pausing the consumer still a meaningful test of the same property when both
   the queue and the consumer are no longer pods in that namespace? Check the arithmetic guards
   (`-gt` against a possibly empty `after_len`) for a false PASS, and whether R8's `sleep 5` still
   covers the worker's reconnect-to-out-of-cluster-Postgres path.
5. Review R9 in full: the `-z` guard before, `docker restart`, a 60-iteration `pg_isready` poll, a
   wait for the `result` Deployment, the `-n` guard after, and the comparison. Does `docker restart`
   test the same property that deleting the StatefulSet pod did — that the tally is persisted, not
   merely that the process came back? Does it prove the named volume was used rather than infer it
   from an unchanged count, and is the "result reconnected" loop doing anything measurable or just
   adding latency?
6. R10 and R11 now count 3 and query `kubectl get deploy -n "$NS"` instead of
   `kubectl get deploy,statefulset` cluster-wide. Is 3 the right count for "every workload in the
   app", and does dropping `statefulset` from the query remove a signal that something else in this
   repo relies on? Note that the JIT controller's own Deployment runs in the same namespace — say
   whether namespace scoping is sufficient to keep that from being miscounted.
7. R17 now reads the `jit-postgres` outputs Secret instead of the app's own `voting-app-postgres`
   Secret, and the password is written by the controller rather than owned by the Postgres module.
   Judge whether R17 still asserts the property the requirement states ("credentials come from a
   Secret, not committed manifests") or a weaker one, whether the source-tree grep still covers the
   built manifests, and whether anything else in the cluster now carries the password in the clear.
8. Trace the container-name convention: `verify.sh` builds `${NS}-redis-redis` and
   `${NS}-postgres-postgres` from `NS`; the modules name containers `${var.name}-redis` /
   `${var.name}-postgres`; the controller sets `var.name`. Confirm the convention holds for any
   namespace, since S17 re-runs this verification in `voting-a`. Then name everything in
   `verify.sh` that still assumes `default` — `RELEASE`, the `vote.localhost` / `result.localhost`
   URLs, R14's cluster-wide Service scan, R15's unscoped pod list — and say which of those are real
   defects for S17 and which are out of this step's scope.
9. `app/docs/MANUAL-TESTING-GUIDE.md` was rewritten wherever it mirrored a reworked check. Verify
   the substituted commands are correct for a reader who has not read `verify.sh`, that the
   architecture recap now matches the deployed topology, and that the guide claims nothing about
   pgAdmin, the JIT stack or the destroy path that this step did not establish.
10. `docs/lessons.md` gained two entries and `docs/todo.md` two S17 flags: the `jit-pgadmin` Service
    advertising 6379 because the controller defaults `int(outputs.get("port", "6379"))` and the
    pgadmin module exposes no `port` output, and the decision to leave the frozen
    `scripts/checks/S00.sh` failing (`FAIL: voting-app-redis not ready`, exit 1) rather than re-open
    or retire it. Judge both: is the 6379 finding correctly characterised and correctly deferred,
    and is a permanently failing frozen gate an acceptable state to carry into S17?
11. Confirm R1, R5 and R12-R15 are unchanged in substance. R12 still `sed`s the registry hostname
    into the base rather than building `overlays/registry` — say whether reworking the checks that
    read the stateful tiers should have caught that too. Then say whether replacing the Stage A app
    in `default` with the migrated one invalidates anything else in the repo: app/README.md,
    app/docs/SCRIPTS-GUIDE.md, app/docs/decisions/, or the checkpoints S01-S14.
12. Assess the checkpoint's own coverage: it has run three times (exit 0 each). Name anything S16's
    rework changed that `S16.sh` cannot observe at all — for example behaviour outside `default`,
    the pgAdmin path, or the destroy path — and whether that is acceptable for this step.
13. Write docs/reviews/S16-findings.md with CLEAR / BLOCKED / CONCERNS.

Do not start S17.
