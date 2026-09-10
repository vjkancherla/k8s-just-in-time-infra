# S15 Review Prompt

**Step:** S15
**Goal:** the app runs with no stateful workload in the cluster.

**Commit range:** 1b50388 → 354f8bc → c2e01a0 → bf77a21 (S14 review prompt, memory bank,
S-1 gate scripts, S15 migration)

**Files changed:**
- app/kustomize/base/*.yaml (the manifests; redis-deployment, redis-service,
  postgres-statefulset, postgres-service and postgres-secret.env are gone)
- app/kustomize/kustomization.yaml (new — a wrapper over base/)
- app/kustomize/overlays/registry/kustomization.yaml (resources: ../../base)
- app/kustomize/overlays/voting-a/kustomization.yaml, overlays/voting-b/kustomization.yaml (new)
- app/scripts/deploy.sh (modified), app/scripts/cleanup.sh (modified), app/Makefile (modified)
- app/README.md, app/docs/SCRIPTS-GUIDE.md, app/docs/MAKEFILE-GUIDE.md, app/.gitignore (modified)
- jit-controller/main.py (modified)
- docs/todo.md (check box ticked)
- scripts/checks/S15.sh, S16.sh, S17.sh (new — these arrive in c2e01a0, see note 1)

**Note on the range:** `app/` was never committed, so the manifests land as additions rather than
moves and the deleted manifests leave no deletion record in the diff. `c2e01a0` touches
`scripts/checks/`, which S-1's own rules put out of a step's review range; it is there because S-1
was incomplete. Treat S15.sh, S16.sh and S17.sh as frozen gates, not as S15's work.

**Checkpoint to run:** `bash scripts/checks/S15.sh`

**Instructions:**
1. Read docs/build-plan.md Stage E and S15. S-1 never completed: only S00-S14 existed, so this step
   had no gate. S15.sh, S16.sh and S17.sh were written from the build plan's own assertions, then run
   to prove they fail cleanly (exit 1, readable messages) before any implementation. Judge whether
   that is an acceptable repair of S-1 or whether writing a gate in the same session as the code it
   gates invalidates both - and whether S15.sh earns its keep now.
2. Review the migration against S15's "Do": no Redis Deployment/Service, no Postgres StatefulSet/
   Service/PVC anywhere in app/kustomize; `vote` annotated with redis, postgres and pgadmin and
   `worker` with redis only; database name `voting`; `postgres-secret.env` and the `openssl` step in
   deploy.sh gone. `softDeleteTTL: 10m` on every claim is a choice, not a requirement - judge it.
3. Review the Kustomize layout change. The manifests moved to `base/` and overlays now reference
   `../../base`, because the previous layout put the overlay inside the base's own tree and
   `kubectl kustomize kustomize/overlays/registry` failed with "cycle detected". Check the new
   structure is sound, that `kustomize/` still builds as the un-namespaced entry point, and that
   R12's sed-based override still describes reality.
4. Review the env rewiring in the three Deployments: `REDIS_URL` → `jit-redis`, `PGHOST` →
   `jit-postgres`, `PGPASSWORD` → `secretKeyRef jit-postgres/POSTGRES_PASSWORD`, `SECRET_KEY` → its
   own `voting-app-secret-key` Secret. Both initContainers (worker's schema DDL, result's wait) must
   follow. Check nothing still points at a Service that no longer exists.
5. Review the credential design - the part most likely to be wrong, and a deliberate deviation.
   The plan says "the Postgres module generates the password and the controller writes it into the
   JIT outputs Secret". It does not: the controller generates it per namespace, reuses the value
   stored in the `jit-postgres` Secret (so re-provisioning never rotates it), writes it into that
   Secret as `POSTGRES_PASSWORD`, and injects `postgres_password` and `postgres_url` into pgadmin's
   params. The reason it does not ride back as a module output is that the runner parses
   `tofu output` in plain text, where a sensitive value renders as the literal `<sensitive>` - the
   postgres module's `url` output is already in that state. Judge (a) whether that reasoning is
   correct, (b) whether the password should instead be a module output with the runner switched to
   `-json`, and (c) whether the idempotency actually holds across a controller restart and a resync.
6. Review the destroy path: `destroy_infra` reads the password back from the `jit-postgres` Secret,
   which `cleanup_k8s_resources` deletes only after a successful destroy, and substitutes a
   placeholder when the Secret is already gone. Check the ordering is real at all three call sites
   and that the placeholder cannot mask a destroy that removed nothing.
7. Check the pgadmin dependency handling: when the `jit-postgres` Secret is absent, provisioning
   returns leaving the claim pending rather than setting `Failed`, because resync treats `Failed` as
   terminal until the Deployment changes. Verify that reasoning against the resync code and that the
   claim genuinely converges instead of spinning.
8. `app/scripts/verify.sh` is deliberately untouched, so R2, R8, R9, R10, R11, R16 and R17 now fail -
   S16 exists to rework exactly those (and is told not to touch R1, R3-R7 or R12-R15). Confirm this
   step claims nothing about `make verify` and that the checkpoint does not depend on it.
9. Frozen `scripts/checks/S00.sh` asserts "all 5 workloads Ready" and "17 PASS, 0 FAIL" - both
   invalidated by this migration. Say whether a stale frozen gate should be re-opened, annotated, or
   left alone, and whether anything else in S00-S14 has silently stopped passing.
10. `modules/pgadmin` publishes a fixed host port (`http_port`, default 5050) on the host, so S17's
    two namespaces cannot both run pgAdmin. Judge severity and whether it belongs in S15 or S17.
11. The Flask `SECRET_KEY` is now a committed literal in its own Secret (a PoC dev value). R17 scopes
    only `POSTGRES_PASSWORD`, so nothing mechanically objects. Judge whether that is an acceptable
    trade for removing the openssl step, or whether it should be generated.
12. Review S15.sh's assertions for vacuity - particularly the config-file checks in Phase 1, which
    assert that files and grep patterns are absent rather than that behaviour is correct.
13. Write docs/reviews/S15-findings.md with CLEAR / BLOCKED / CONCERNS.

Do not start S16.
