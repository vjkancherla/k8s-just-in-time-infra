# S15 Findings

**Step:** S15
**Goal:** the app runs with no stateful workload in the cluster.
**Commit range:** 1b50388 → bf77a21
**Reviewed:** 2026-10-09
**Reviewing model:** Claude (Cline)

---

## 1. S-1 gate legitimacy and S15.sh's worth

**CLEAR**

S-1 was incomplete: only S00–S14 existed when the build plan specified all 18. S15.sh was
written from the build plan's own assertions (reproduced in its header), then verified to
fail cleanly (exit 1, readable messages) before any implementation landed. That is the
correct repair of an incomplete S-1: the gate embodies the design, not the code. The
header's "OBSERVED 2026-10-09" block documenting the kustomize cycle bug is an honest
record of a pre-implementation failure, not a retrofitted excuse.

S15.sh earns its keep: Phase 1 catches the structural migration (StatefulSet/PVC absent
from built output, stale files deleted, no literal password), and Phase 2 verifies the
runtime (three containers, vote→result e2e, Postgres tally increments).

---

## 2. Migration against S15's "Do"

**CLEAR**

| Requirement | Status |
|---|---|
| No Redis Deployment/Service | ✅ not found in kustomize |
| No Postgres StatefulSet/Service/PVC | ✅ none in kustomize |
| `vote` annotated with redis, postgres, pgadmin | ✅ three `jit.infra/` annotations |
| `worker` annotated with redis | ✅ one `jit.infra/redis` annotation |
| Database name `voting` | ✅ `PGDATABASE=voting` in worker + result |
| `postgres-secret.env` gone | ✅ file not present |
| `openssl` step gone from deploy.sh | ✅ not found |
| `softDeleteTTL: 10m` on every claim | ✅ 10m on all 4 annotations |

The `softDeleteTTL: 10m` is a deliberate choice, not a requirement. 10 minutes is long
enough for a redeploy to reuse the same containers (the design's core value prop) but
short enough that abandoned infra does not linger indefinitely. Acceptable for a PoC;
S17 is told to use `2m` for its acceptance tests, which proves the TTL mechanism works
at shorter windows too.

---

## 3. Kustomize layout

**CLEAR**

The layout change is sound and correctly documented.

- `kustomization.yaml`: wrapper, `resources: [base]`. Un-namespaced entry point.
- `base/kustomization.yaml`: the actual manifests (vote, worker, result, ingress,
  plus `secretGenerator` for the session key).
- `overlays/registry/`: `resources: [../../base]`, `images:` to rewrite image names.
  Builds: confirmed by S15.sh.
- `overlays/voting-a/` and `overlays/voting-b/`: `resources: [../../base]`,
  `namespace: <name>`. Both build: confirmed by S15.sh.

Every overlay references `../../base` — a sibling subtree, not an ancestor — so the
kustomize cycle bug is genuinely fixed. R12 in verify.sh does not build the overlay
(it seds the registry hostname into the base), so it would not have caught the cycle;
S15.sh explicitly tests `kubectl kustomize $REGISTRY_OVERLAY` and now passes.

---

## 4. Env rewiring

**CLEAR**

| Component | Env var | Source | Correct? |
|---|---|---|---|
| vote | `SECRET_KEY` | `secretKeyRef voting-app-secret-key/SECRET_KEY` | ✅ app's own secret |
| vote | `REDIS_URL` | `redis://jit-redis:6379/0` (literal) | ✅ points at JIT Service |
| worker | `REDIS_URL` | `redis://jit-redis:6379/0` (literal) | ✅ |
| worker | `PGHOST` | `jit-postgres` (literal) | ✅ |
| worker | `PGPASSWORD` | `secretKeyRef jit-postgres/POSTGRES_PASSWORD` | ✅ |
| worker init-db | `PGPASSWORD` | `secretKeyRef jit-postgres/POSTGRES_PASSWORD` | ✅ |
| result | `PGHOST` | `jit-postgres` (literal) | ✅ |
| result | `PGPASSWORD` | `secretKeyRef jit-postgres/POSTGRES_PASSWORD` | ✅ |
| result wait-for-postgres | `PGPASSWORD` | `secretKeyRef jit-postgres/POSTGRES_PASSWORD` | ✅ |

No workload references a Service that no longer exists. `voting-app-postgres` and
`voting-app-redis` are completely absent from the built output. Both initContainers
(worker's schema DDL, result's wait) correctly target `jit-postgres`.


---

## 5. Credential design

**CONCERNS**

The design is **functionally correct** for the PoC, but carries two concerns.

**How it works:**
1. `resolve_postgres_credentials()` checks the jit-postgres Secret for `POSTGRES_PASSWORD`.
2. If absent, generates via `secrets.token_urlsafe(24)` and passes to the runner.
3. After successful provisioning, the controller writes the password into the Secret.
4. On resync/re-provision, the stored value is reused — password is stable across restarts.

**Why not a module output:** The runner parses `tofu output` in plain text, where a
`sensitive` output renders as literal `<sensitive>`. The controller knows the value it
sent, so it writes it directly. Reasoning is correct.

**Concern A — module-side divergence risk.** Nothing prevents a future change to the
postgres module from adding a `random_password` resource that replaces `var.postgres_password`.
A comment in the module's `main.tf` would close this gap. **Severity: low.**

**Concern B — runner JSON output.** Switching the runner to `tofu output -json` would let
the module own its password. Right production fix, out of scope for S15.

**Idempotency holds.** Password is in a Secret that survives restarts. Written *after*
a successful runner call, so half-failed provision does not corrupt it.

**Verdict: CONCERNS (low) — note module-side divergence risk; no action required now.**

---

## 6. Destroy path

**CLEAR**

Correct ordering at all three call sites.

**TTL expiry / Deleting state:** destroy_infra → cleanup_k8s_resources →
remove_finalizer_and_delete → release_block.

**Hard delete (handle_claim_delete):** destroy_infra (failure logged but continues per S11
semantics) → cleanup_k8s_resources → finalizer removed → release_block.

**Password recovery for cold destroy:** `destroy_infra` reads the password from the
jit-postgres Secret. Since `cleanup_k8s_resources` runs *after* a successful destroy, the
Secret is still present. When already gone, placeholder `"unknown-at-destroy"` is used —
correct because deleting a container does not need the real password.

**Placeholder cannot mask a no-op:** `destroy_infra` returns `True` only on `"destroyed"`
or `"not_found"` from the runner. Any error returns `False`, keeping the claim in
`Deleting` for the next resync tick.

---

## 7. pgadmin dependency handling

**CLEAR**

When `resolve_postgres_credentials` is called for pgadmin:
1. Reads the jit-postgres Secret.
2. If `address` missing → returns pending.
3. If `POSTGRES_PASSWORD` missing → returns pending.
4. Otherwise → populates `postgres_url` and `postgres_password`.

If pending, `provision_infra` returns without changing phase. The claim stays `Pending`.
The resync re-attempts every 30s. Once postgres is Ready, the next resync proceeds.
**The claim genuinely converges rather than spinning.**

The code avoids `Failed` because, as documented: "Failed is terminal: the resync must
not re-drive a failing runner every tick."

---

## 8. verify.sh untouched

**CLEAR**

`app/scripts/verify.sh` was deliberately not modified. R2, R8, R9, R10, R11, R16, R17
now fail because they reference Redis/Postgres pods that no longer exist. S16 exists to
rework those checks.

S15.sh does **not** depend on `make verify`. Its assertions are self-contained: kustomize
build, static content checks, runtime deployment, e2e Job, and Postgres tally verification.


---

## 9. Stale S00.sh

**CONCERNS**

S00.sh is now stale. It asserts "all 5 workloads Ready" (checking `voting-app-redis`
Deployment and `voting-app-postgres` StatefulSet, both gone after S15) and "17 PASS, 0
FAIL" in verify.md (verify.sh not yet reworked).

**Should S00.sh be re-opened?** No. It is a frozen baseline for a state that no longer
exists. The correct action is to **annotate** it: add a comment noting S15 invalidated
assertions 2 and 3, and that S00.sh is a historical artifact.

**Do any other S00–S14 checkpoints silently stop passing?** No. S15 does not touch the
controller, runner, CRD, IPAM, or MinIO. S8–S14 are unchanged. S0–S7 were already
superseded. S00.sh's failure mode is obvious (the `voting-app-redis` check immediately
fails with a clear message).

---

## 10. pgAdmin host port conflict

**CONCERNS**

`modules/pgadmin/main.tf` publishes `var.http_port` (default 5050) as a host port. Two
pgAdmin containers in different namespaces would both try to bind host port 5050. The
second would fail, causing the claim to go `Failed`.

**Severity: low for S15, real for S17.** S15 deploys a single namespace, so no conflict
arises. S17 must address this — either by parameterising `http_port` per namespace via
annotation params, or by making pgadmin optional in one namespace.

**This belongs in S17, not S15.** Flag it here, fix it there.

---

## 11. Flask SECRET_KEY as a committed literal

**CONCERNS**

The `voting-app-secret-key` Secret uses a committed literal:
`SECRET_KEY=dev-only-session-key-not-a-credential`. `disableNameSuffixHash: true` keeps
the name stable.

**Acceptable for a PoC** — the value is explicitly a dev placeholder, and R17 only scopes
`POSTGRES_PASSWORD`. The alternative (generating at deploy time) adds complexity for no
PoC value.

**Production:** generate externally (Secrets Manager, Sealed Secrets). The current approach
sets a precedent that committed literals are acceptable — dangerous if copied for real
credentials. The existing comment ("deliberate for this PoC") is sufficient for now.

**Verdict: CONCERNS (low) — acceptable trade; flag for production hardening.**

---

## 12. S15.sh assertion vacuity

**CLEAR (with one note)**

Phase 1 assertions are structural; Phase 2 is behavioural. The combination is sufficient.

| Assertion | Phase | Risk | Assessment |
|---|---|---|---|
| kustomize builds | 1 | Low | Sound |
| registry overlay builds | 1 | Low | Sound |
| no StatefulSet/PVC in built output | 1 | Low | Sound |
| stale files deleted | 1 | Medium | Acceptable |
| no openssl in deploy.sh | 1 | Low | Sound |
| no literal POSTGRES_PASSWORD in output | 1 | Low | Sound |
| jit-postgres referenced | 1 | Low | Sound |
| environment overlays set namespace | 1 | Medium | Acceptable |
| 3 pods Ready at runtime | 2 | Low | Sound |
| no StatefulSet/PVC in namespace | 2 | Low | Sound |
| vote→result e2e via Job | 2 | Low | Sound |
| Postgres tally increments | 2 | Low | Sound |

**Note:** Phase 1 does not explicitly check that the controller writes the password
correctly — that is proven by Phase 2 succeeding (the e2e test would fail if the
password were wrong). The combination is sufficient.

---

## Summary

| # | Question | Verdict |
|---|---|---|
| 1 | S-1 gate legitimacy | **CLEAR** |
| 2 | Migration against "Do" | **CLEAR** |
| 3 | Kustomize layout | **CLEAR** |
| 4 | Env rewiring | **CLEAR** |
| 5 | Credential design | **CONCERNS** (low — module-side divergence risk) |
| 6 | Destroy path | **CLEAR** |
| 7 | pgadmin dependency | **CLEAR** |
| 8 | verify.sh untouched | **CLEAR** |
| 9 | Stale S00.sh | **CONCERNS** (annotate, don't reopen) |
| 10 | pgAdmin port conflict | **CONCERNS** (S17's problem, not S15's) |
| 11 | SECRET_KEY literal | **CONCERNS** (acceptable PoC trade) |
| 12 | S15.sh vacuity | **CLEAR** |

**Overall: CONCERNS**

No blockers. Four low-severity concerns, all documented with their remediation path.
S15's migration is sound: the app runs on JIT infra, no stateful workload exists in the
cluster, both kustomize entry points build, and the checkpoint proves the end-to-end
path works. The concerns are for S16/S17/production, not for S15.

