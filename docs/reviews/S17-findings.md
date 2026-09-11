# S17 Review Findings

**Reviewer:** Claude (different model, fresh task)
**Commit range:** a82a6a9 → c95c051
**Date:** 2026-11-09

---

## 1. Checkpoint

`bash scripts/checks/S17.sh` → exit 0, live run:

```
PASS: root Makefile declares jit-up
PASS: root Makefile declares jit-verify
PASS: root Makefile declares jit-down
PASS: root Makefile declares check
PASS: make check STEP=NN routes to scripts/checks/SNN.sh
  J11 PASS jit-state holds ns/voting-a/{redis,postgres,pgadmin}/terraform.tfstate ...
  ===== 11 PASS, 0 FAIL =====
PASS: make jit-verify exited 0 and wrote .workflow/verify-jit.md
PASS: J1-J11 all PASS in .workflow/verify-jit.md
PASS: voting-a runs the migrated app on three containers, no StatefulSet, no PVC
  ===== 17 PASS, 0 FAIL =====
PASS: S17 - two namespaces, J1-J11 and the R-checks both green
EXIT:0
```

The recorded evidence (`docs/evidence/s17-run-postfix.log`) corroborates this. All
assertions pass.

## 2. J1–J11 against the design note

Every J-check maps directly to the design note's verification table:

| J | Design says | Verdict |
|---|---|---|
| J1 | 3 claims Ready, 3 containers on .10x | **Satisfied** |
| J2 | Secrets/Services/EndpointSlices + R1-R17 pass | **Satisfied** |
| J3 | pgAdmin reachable, Postgres registration works | **Satisfied** |
| J4 | `delete deploy` → Orphaned, containers running | **Satisfied** |
| J5 | Redeploy → same containers, tally intact | **Satisfied** |
| J6 | Delete past TTL → containers destroyed | **Satisfied** |
| J7 | `vote`+`worker` annotate redis; delete `vote` → redis stays Ready | **Satisfied** |
| J8 | Delete ns → immediate teardown, other ns untouched | **Satisfied** |
| J9 | Controller restart → orphan detected | **Satisfied** |
| J10 | Runner stopped → claims Failed | **Satisfied** |
| J11 | MinIO: one state object per namespace-module | **Satisfied** |

The four that matter (J4, J5, J8, J9) all pass. The suite uses `set -euo pipefail` and
exits non-zero on the first failure — correct for a gate.

## 3. namespace_lock and the IPAM guarantee

The design specifies "a block of 10 per namespace" and `allocate_block` counts claims.
The design does not specify that the address pick must be atomic. In practice, kopf fires
both `on.create` and `on.update` for a single Deployment apply, iterating every claim —
without a lock, two claims read the same taken set and get the same address.

`namespace_lock` is a process-local `threading.Lock` per namespace, guarding the
read-pick-patch in `ensure_claim`. This is sufficient for a single-controller-replica
PoC, which the code and docs assume. The design's guarantee is upheld; the mechanism
changed, not the contract. `ipam.py` has no lock of its own, and `_allocated_ip`
returning `""` on `ApiException` is indistinguishable from "no address" — both are
known latent issues, not regressions from S17.

## 4. J11 prefix encoding and missing pass()

Two defects in `scripts/verify-jit.sh`:

1. **Prefix encoding.** The S3 ListObjectsV2 canonical query string uses `%2F` for `/`,
   not raw `/`. Signing `ns/` (safe="/") made MinIO answer 403 SignatureDoesNotMatch.
   Fixed: `urllib.parse.quote(prefix, safe="")`. The design note says nothing about how
   to read the state bucket; the check implements "distinct prefixes" correctly now.

2. **Missing `pass()` call.** J11's assertions are all negative (`fail` calls). Without
   an explicit `pass()`, a passing J11 printed nothing — the suite exited 0 on ten
   reports, and the checkpoint's `^J11 PASS` gate could never be satisfied.

Both were caught by the frozen checkpoint asserting the PASS line, not just the exit
code. That is exactly right — the checkpoint is more useful than a bare exit code.

## 5. Voting-b, `vote.localhost`, and a third namespace

**voting-a** takes the base without patches: `vote.localhost`/`result.localhost` hosts,
pgAdmin on port 5050. `app/scripts/verify.sh` defaults `VOTE_URL`/`RESULT_URL` to those
hostnames. No conflict.

**voting-b** patches Ingress hosts to `vote-b.localhost`/`result-b.localhost` and the
pgadmin annotation to `http_port: 5051`. This avoids Traefik routing ambiguity and port
collision. R13 is unaffected (only touches voting-a). The design note's Demo section
(two namespaces, delete a Deployment, delete the namespace) is demonstrable: J4/J5
exercise the soft path in voting-a, J8 deletes voting-b.

**A third namespace** (voting-c) could deploy from the same base by patching its own
Ingress hosts and pgAdmin port, following the same pattern as voting-b. The `172.19.0.100-199`
range supports 10 blocks of 10 addresses.

## 6. Explicit-module rule in the runner

The runner's `DestroyRequest.module` is `Optional[str]`, defaulting to `None`. When
`None`, it falls back to the workspace's single cached run. When **explicit**, it always
wins — even if the cache has a different module. This prevents the scenario where the
TTL sweep destroys a claim, the delete handler fires again, and the second call (with no
cached entry) resolves to the wrong module (S17's J6). The fix is correct and necessary.


## 7. pgadmin's servers.json and var.share_dir

**Arrangement:** `deploy/runner.sh` mounts `$HOME/.jit-host-share` into the runner
container and exports `JIT_SHARE_DIR`. The pgadmin module writes `servers.json` to
`${var.share_dir}/pgadmin-servers-${var.name}.json`. The container bind-mounts the file.

**`/tmp` default:** `variables.tf` defaults `share_dir` to `"/tmp"`. The docstring
explains that this only works when tofu runs directly on the daemon's host — otherwise
`/tmp` is the runner container's tmpfs, invisible to the daemon. When the runner supplies
`JIT_SHARE_DIR`, the default is overridden. A direct `tofu apply` on the host without
setting `TF_VAR_share_dir` would silently reproduce the original bug (Docker creating an
empty directory). This is documented in the variable's description; adequate for a PoC.
A production version should remove the default and require it explicitly.

**S05 standalone use:** The pgadmin module depends on `var.share_dir` being a path both
tofu and the daemon can see — not on the runner itself. S05's standalone test runs tofu
directly on the host, where `/tmp` works. No breakage.

**J3** reads the file back (`docker exec pgadmin ... cat /pgadmin4/servers.json`) and
asserts the host and port match. That is sufficient.

## 8. destroy_infra placeholder values

`destroy_infra` falls back to `postgres_password: "unknown-at-destroy"` and
`postgres_url: "unknown-at-destroy:5432"` when the jit-postgres Secret is already gone.
This happens when postgres was destroyed before pgadmin in the same sweep.

**Can a placeholder reach a running container?** No. The placeholder is passed as a
tofu `-var` for the destroy operation, which removes the container. The container is
removed, not restarted with the wrong password.

**Design-note failure mode 3 visibility:** The placeholder makes destroy more likely to
succeed (no "No value for required variable" wedge), which means the claim progresses
to deletion rather than staying stuck in `Deleting` forever. This is *more* visible to
the operator. The earlier wedge was *less* visible — the claim existed but never
progressed. The placeholder trades "destroy silently cannot proceed" for "destroy
succeeds with a harmless dummy value". That is the right direction.

## 9. jit-up re-runnability and jit-down completeness

**`make jit-up` re-runnability:**
- `deploy/minio.sh`: recreates container, 409 handled. Re-runnable.
- `deploy/runner.sh build`: always rebuilds. `down` then `up`. Re-runnable.
- CRD: `kubectl apply` idempotent. Re-runnable.
- Controller: all `kubectl apply` or `--ignore-not-found`. Re-runnable.

Nothing in the sequence assumes a truly cold host. The named volume survives MinIO
recreation.

**`make jit-down` completeness:**
1. InfraClaims: patches finalizer off, deletes each. ✓
2. Leftover containers: `docker rm -f` by name pattern. ✓
3. Controller: `kubectl delete -f deploy/controller.yaml`. ✓
4. Runner: `deploy/runner.sh down`. ✓
5. MinIO: `docker rm -f minio`. ✓

**What it leaves behind:**
- The CRD — deliberately left (cheap to re-apply). Documented in script header.
- The `jit-ipam` ConfigMap — not removed. A stale ledger could cause `count` drift
  (blocks never reaching zero). Works in practice for the PoC but is a latent concern.
- Named Docker volumes (e.g., `voting-a-postgres-data`) — not removed. Intentional.
- Tenant namespaces and their Deployments — deliberately not touched.

## 10. README escape hatch (§"If it goes wrong")

Walking through as a reader who has never seen this repo:

**Step 1:** `kubectl get infraclaims` — clear, shows what is wedged.

**Step 2:** Manual tofu destroy.
- `cp -r jit-modules/modules/<module> /tmp/wedged` — reasonable.
- `export AWS_ACCESS_KEY_ID=...` from `deploy/.env` — grep syntax correct.
- `tofu init -backend-config=...` — flags are **complete**: bucket, key
  (`ns/<ns>/<module>/terraform.tfstate`), endpoint, region, access/secret keys,
  skip_credentials_validation, skip_metadata_api_check, force_path_style. The state key
  format matches the runner's `_state_key`.
- `tofu destroy -auto-approve -var name=<ns>-<module> -var network=k3d-voting-app -var ip=<ip>`
  — correct for **redis**. The doc then names the extra vars for postgres (`postgres_password`)
  and pgadmin (`postgres_url` + `postgres_password`). This matches `variables.tf` exactly.
- The note about `-var http_port=<n>` for pgadmin is correct (default 5050).

**Step 3:** Strip the finalizer — correct kubectl patch syntax.
- **IP block:** If the claim was in `Deleting` (the usual wedge state), `handle_claim_delete`
  checks `phase == "Deleting"` and skips the release. The automated paths have already
  failed, so the IP block is likely still in the ledger. The operator would need to
  manually clean the `jit-ipam` ConfigMap, or accept the leaked block. **Not documented**
  in the escape hatch — a minor gap.

**Step 4:** `make jit-down` — safe when a workspace is still wedged. It patches finalizers
off all claims (including the wedged one), removes containers by name pattern, then tears
down the stack. No conflict.

**The README's rule** ("a destroy that fails for the same reason twice is a design
problem") — the three destroy defects S17 fixed were all design-level gaps (missing
outputs, missing shared directory, incomplete cleanup paths) manifesting as implementation
defects. The rule is well-judged.

## 11. Build plan "Done" list

| Done item | Status |
|---|---|
| `make all` and `make jit-verify` both green from a cold `make destroy` | **Open.** Not run in S17. |
| `docs/todo.md` boxes all ticked | **Partially open.** S-1's check box unticked (by design). S17's review box not yet ticked. |
| Review section in `todo.md` | **Done.** S17 section documents IPAM, J11, voting-b, retention. |
| `docs/lessons.md` | **Done.** Three new entries plus "carried forward" updated. |
| Short note on what production needs | **Done.** Build plan "Done" and lessons.md both list it. |

**Design note open questions, answered by S17:**

- **Annotation edited on a live Deployment:** Re-applies (first writer wins).
- **Visibility of `Orphaned` infra:** Visible to platform operator via `kubectl get infraclaims`;
  tenant visibility not addressed (still open).
- **IP-block reuse:** Immediate, not quarantined. EndpointSlice cleanup happens before
  release, mitigating the stale-address concern.

## 12. Verdict

**CONCERNS**

No blockers. The code is clean, the evidence is thorough, and the three defects S17
found and fixed were all caught by the verification process working as designed.

Concerns:

1. **`jit-down` does not reset the `jit-ipam` ConfigMap.** A `make jit-down` then
   `make jit-up` then fresh deploy starts with a stale ledger. Harmless for the PoC;
   production needs the ConfigMap cleared or IPAM idempotent against stale state.

2. **The escape hatch does not mention the IPAM ledger.** An operator who strips the
   finalizer and runs `make jit-down` leaves a stale entry. The README should note this.

3. **`var.share_dir` default `"/tmp"` silently reproduces the original bug** when tofu
   runs directly on the daemon's host without `TF_VAR_share_dir`. Documented in
   `variables.tf` but a trap for standalone use.

4. **The "Done" item "a cold `make destroy`" is not exercised.** S17 ran `make jit-verify`
   and `make verify` separately, not `make all` from a cold destroy.

5. **Tenant visibility of `Orphaned` claims is not addressed.** The design's open question
   is still open. Fine for a PoC.

None of these are blockers. S17 satisfies the design note's verification table, the
build plan's S17 deliverables, and its own checkpoint.

