# S17 Review Prompt

**Step:** S17
**Goal:** the demo, and the acceptance tests from the design note.

**Commit range:** a82a6a9 → e00a179 (seven commits)

**Files changed:**
- jit-controller/main.py (namespace_lock; release_block released once; Service re-stated on 409;
  pgadmin's destroy variable; a logger level)
- jit-modules/modules/pgadmin/{main.tf,outputs.tf,variables.tf} (the port output, var.share_dir,
  Host/Port split out of postgres_url)
- jit-runner/main.py, deploy/runner.sh (an explicit module always wins; a logger; the shared dir)
- Makefile, scripts/jit-up.sh, scripts/jit-down.sh, scripts/verify-jit.sh, README.md, RUNBOOK.md
- app/kustomize/overlays/voting-a/kustomization.yaml, app/kustomize/overlays/voting-b/kustomization.yaml
- app/scripts/verify.sh, app/README.md, app/docs/SCRIPTS-GUIDE.md
- docs/todo.md, docs/lessons.md

**Note on the range:** one commit in it is not S17's work. `15991b5` adds files that predate this
step and had never been committed — `app/vote`, `app/worker`, `app/result`, `app/scripts/build.sh`,
`scripts/checks/S01.sh`-`S07.sh` and `deploy/minio.sh` — because the S17 checkpoint cannot run
without them. Nothing in that commit was modified; if you want to judge a file's diff, read the file.
`scripts/checks/S17.sh` arrived earlier, in an S-1 commit, and is a **frozen** gate: judge it, do not
expect it to have changed.

**Checkpoint to run:** `bash scripts/checks/S17.sh`

**Instructions:**
1. Read docs/build-plan.md S17 and docs/todo.md. The checkpoint asserts the four Makefile targets
   exist, that `make check STEP=15` routes to `scripts/checks/S15.sh`, that `make jit-verify` exits 0
   and wrote `.workflow/verify-jit.md` with `^J1`-`^J11 PASS` lines and no FAIL, and that
   `make verify` reports `17 PASS, 0 FAIL` in voting-a. Judge whether that is independent of the
   implementation it gates — in particular whether grepping the Makefile for a target name can pass
   vacuously when the script must have that target to run at all — and whether the failure output
   names the failing check clearly enough to diagnose from the log alone.

2. The step's own text names four checks that matter: J4, J5, J8, J9. For each, say whether the
   assertion tests the property the build plan names ("infra keeps running, other workloads
   unaffected", "same containers, data intact", "immediate teardown, the other namespace untouched",
   "orphan still detected") or a weaker proxy for it.

3. The defect this step opened with: two claims in one namespace were handed the same IP. Judge
   `namespace_lock(namespace)` as the fix — process-local, per namespace, held across an API read
   *and* an API write. Is in-process serialisation sufficient under the documented single-replica
   assumption, and is the assumption itself stated anywhere a future reader will find it? Then name
   every code path that mutates the IPAM ConfigMap or a claim's `status.allocatedIP` and say whether
   all of them are inside a lock.

4. `handle_claim_delete` now skips `release_block` when the claim's phase is already `Deleting`. Is
   that a sound proxy for "the sweep already released this block", or can a claim be `Deleting` for
   another reason, or fail to be `Deleting` when it should be, and leak or double-release the block?
   Trace the ledger for: a namespace deleted while its claims are `Failed`, a claim deleted by hand
   while `Ready`, and a claim whose finalizer is removed by the README's escape hatch.

5. `_allocated_ip` returns `""` on any ApiException and `""` means "unallocated", so a transient API
   error during a re-sync can make `ensure_claim` allocate a *second* address for a claim whose
   container is already using the first. Say whether that is reachable in practice, whether the
   container's IP would then disagree with `status.allocatedIP`, and whether J1's
   container-IP-matches-status assertion would catch it.

6. The evidence that the race is fixed is `/tmp/race-test.sh` — three clean-slate deploys, each
   requiring three distinct IPs — and not the checkpoint. Judge whether three iterations is adequate
   for a two-thread interleaving, whether the test is *capable* of failing (say what it prints on a
   duplicate, and whether it would exit non-zero), and whether a fix whose only regression test lives
   in `/tmp` is acceptable for a frozen step.

7. J11 had two defects that no earlier run could reveal, because no run had ever reached it: a SigV4
   canonical-query bug (`safe="/"` signed `prefix=ns/`, where the canonical form is `ns%2F`, so MinIO
   answered 403) and no `pass` line at all, so a *passing* J11 printed nothing. Judge both fixes, and
   then judge the class of bug: what would have caught "a check whose assertions are all negative
   reports nothing" before a human read two logs? Is the repo's convention — or a lint — missing
   something that should be written down?

8. `scripts/checks/S17.sh` greps the artifact for `^J11 PASS` and separately for a FAIL anywhere.
   Given J11's history, say whether the gate should also assert a *count* or the summary line
   (`===== 11 PASS, 0 FAIL =====`), and whether accepting the artifact at either `.workflow/` or
   `app/.workflow/` weakens it. Note the gate runs `make jit-verify` with `set -euo pipefail`, so the
   suite's exit code and its artifact are both load-bearing.

9. `voting-b` patches the shared base for the ingress hosts and `params.http_port`. Judge patching
   versus parameterising the base, and name anything else that must differ per namespace but was not
   patched — consider `vote.localhost` in `app/scripts/verify.sh`'s defaults, R13's expectations,
   and whether a third namespace could deploy from this base at all.

10. pgadmin's `servers.json` is now written to `var.share_dir`, and `deploy/runner.sh` mounts
    `$HOME/.jit-host-share` into the runner and exports `JIT_SHARE_DIR`. Judge this arrangement: is a
    directory under `$HOME` acceptable, does the `"/tmp"` default in `variables.tf` silently
    reproduce the original bug (Docker creating an empty directory) when tofu runs directly on the
    daemon's host, and does the module now depend on the runner in a way that breaks S05's standalone
    use?

11. `destroy_infra` falls back to placeholder values for `postgres_password` and `postgres_url` when
    the postgres Secret is already gone. Say whether that makes a destroy able to succeed while
    leaving the wrong thing running or removing the wrong container, whether a placeholder can ever
    be passed into a container that stays up, and how this interacts with the runner's
    explicit-module rule from the same commit.

12. S17 is the last step. For each item in the build plan's "Done" list, say whether S17 leaves it
    satisfied or open — in particular "docs/todo.md boxes all ticked" (S-1's box is unticked and the
    review boxes for S8-S16 were not touched), "`make all` and `make jit-verify` both green from a
    cold `make destroy`" (not run in this step; a cold `make destroy` is the one path J1's fix does
    not exercise), and "a short note on what production needs that this omits".

13. Write docs/reviews/S17-findings.md with CLEAR / BLOCKED / CONCERNS.

There is no step after S17. Do not start anything new; report the findings.
