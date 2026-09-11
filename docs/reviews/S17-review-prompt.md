# S17 Review Prompt

**Step:** S17
**Goal:** the demo, and the acceptance tests from the design note.

**Commit range:** a82a6a9 → e00a179 (seven commits: the implementation, its fixes and the step's docs)

**Outside that range, for context:** bookkeeping only, no implementation — `memory-bank/*`, and
`docs/reviews/` (this prompt plus the S08-S15 artifacts that had never been committed).

**Read first, in this order:** `docs/jit-infra-poc.md` §Verification (the J1-J11 table) and its
§Failure modes (four of them; "Destroy fails → finalizer held, namespace stuck in `Terminating`,
escape hatch documented" is item 3), then `docs/build-plan.md` S17, then `docs/todo.md`. The
J-checks exist to satisfy the design note's table — judge them against the design note, not against
the implementation that grew around them.

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
expect it to have changed. The two defects J11 turned out to have were in
`scripts/verify-jit.sh` — which is *not* frozen, it is this step's deliverable.

**Checkpoint to run:** `bash scripts/checks/S17.sh`

**Instructions:**
1. The checkpoint asserts the four Makefile targets exist, that `make check STEP=15` routes to
   `scripts/checks/S15.sh`, that `make jit-verify` exits 0 and wrote `.workflow/verify-jit.md` with
   `^J1`-`^J11 PASS` lines and no FAIL, and that `make verify` reports `17 PASS, 0 FAIL` in
   voting-a. Judge whether that is independent of the implementation it gates — in particular
   whether grepping the Makefile for a target name can pass vacuously when the gate script must
   `cd` to the repo and read `Makefile` to run at all — and whether the failure output names the
   failing check clearly enough to diagnose from the log alone. Both earlier failures of this gate
   exited 0; say what that says about relying on the exit code anywhere in this repo.

2. Take the design note's §Verification table as the specification and check J1-J11 against it, one
   by one. Name any check whose assertion is a weaker proxy than the design note's wording —
   consider J4's "worker still functioning" (asserted as "a vote lands within three attempts"), J6's
   "containers destroyed, Secrets and Services removed" (does the design note's "containers" include
   the data volume?), and J10's "pods do not start" (asserted partly as "no ready replicas"). Then
   say whether any row of the design note's table is *not asserted at all*, and whether the build
   plan's "four that matter" (J4, J5, J8, J9) is a subset of the design note's own emphasis
   (J4/J5 soft path, J8 hard path, J7 refcount, J9 the one most designs skip) or a competing claim.

3. The defect this step opened with: two claims in one namespace were handed the same IP. Judge
   `namespace_lock(namespace)` as the fix — process-local, per namespace, held across an API read
   *and* an API write. Is in-process serialisation sufficient under the documented single-replica
   assumption, and is that assumption stated anywhere a future reader will find it? Then name every
   code path that mutates the IPAM ConfigMap or a claim's `status.allocatedIP` and say whether all of
   them are inside a lock. Include `_allocated_ip`'s habit of returning `""` on any ApiException:
   `""` means "unallocated", so a transient API error during a resync can allocate a *second*
   address for a claim whose container already uses the first. Is that reachable, and would J1's
   container-IP-matches-status assertion catch it?

4. `handle_claim_delete` now skips `release_block` when the claim's phase is already `Deleting`. Is
   that a sound proxy for "the sweep already released this block", or can a claim be `Deleting` for
   another reason, or fail to be `Deleting` when it should be? Trace the ledger for a namespace
   deleted while its claims are `Failed`, a claim deleted by hand while `Ready`, and a claim whose
   finalizer is stripped by the README's escape hatch. This is also where the design note's own open
   question lands — "IP block reuse after teardown: immediate, or quarantined a cycle? Immediate
   risks a stale EndpointSlice pointing at another namespace's container." Say which answer this
   implementation chose, whether it was chosen deliberately, and whether the stale-EndpointSlice
   risk is real here.

5. The evidence that the race is fixed is `/tmp/race-test.sh` — three clean-slate deploys, each
   requiring three distinct IPs — and not the checkpoint. Judge whether three iterations is adequate
   for a kopf create+update interleaving, whether the test is *capable* of failing (say what it
   prints on a duplicate, and whether it would exit non-zero), and whether a fix whose only
   regression test lives in `/tmp` is acceptable for a frozen step. Say what you would do instead.

6. J11 had two defects that no earlier run could reveal, because no run had ever reached it: a SigV4
   canonical-query bug (`safe="/"` signed `prefix=ns/`, where the canonical form is `ns%2F`, so MinIO
   answered 403) and no `pass` line at all, so a *passing* J11 printed nothing. Judge both fixes, and
   then the class of bug: what would have caught "a check whose assertions are all negative reports
   nothing" before a human read two logs? Is the repo's convention — or a lint — missing something
   that should be written down? Note that the gate asserts the PASS line and not the exit code, and
   say whether that is the right shape for the other seventeen checkpoints.

7. `voting-b` patches the shared base for the ingress hosts and `params.http_port`. Judge patching
   versus parameterising the base, and name anything else that must differ per namespace but was not
   patched — consider `vote.localhost` in `app/scripts/verify.sh`'s defaults, R13's expectations,
   whether the design note's "Demo" section (two namespaces, delete a Deployment in one, delete the
   namespace) is actually demonstrable in this state, and whether a third namespace could deploy from
   this base at all.

8. pgadmin's `servers.json` is now written to `var.share_dir`, and `deploy/runner.sh` mounts
   `$HOME/.jit-host-share` into the runner and exports `JIT_SHARE_DIR`. Judge this arrangement: is a
   directory under `$HOME` acceptable, does the `"/tmp"` default in `variables.tf` silently
   reproduce the original bug (Docker creating an empty directory) when tofu runs directly on the
   daemon's host, and does the module now depend on the runner in a way that breaks S05's standalone
   use? J3 is the only check that reads the file back; say whether that is enough.

9. `destroy_infra` falls back to placeholder values for `postgres_password` and `postgres_url` when
   the postgres Secret is already gone. Say whether that makes a destroy able to succeed while
   leaving the wrong thing running or removing the wrong container, whether a placeholder can ever
   be passed into a container that stays up, and how this interacts with the runner's
   explicit-module rule from the same commit. Then relate it to design-note failure mode 3: is a
   failed destroy still *visible* to the operator after this change, or has the placeholder made the
   wedge quieter?

10. S17's "Do" list names two targets the questions above do not touch. `make jit-up` must bring up
    MinIO, the runner, the CRD and the controller, and `make jit-down` must remove them "and any
    leftover containers". Judge both against that wording: is `jit-up` genuinely re-runnable (the
    step changed `deploy/minio.sh` to tolerate a 409 from an existing bucket — what else in the
    sequence assumes a cold host?), and does `jit-down` remove what it claims, including claims,
    Secrets, EndpointSlices, containers and volumes, or does it leave state that makes the next
    `jit-up` behave differently?

11. The other named deliverable is the README's wedged-finalizer escape hatch (§"If it goes wrong"),
    which is also design-note failure mode 3. Walk it as a reader who has never seen this repo and
    say whether it works as written: are the `tofu init` backend flags complete and the state key
    correct, are the variables it says to pass the ones the modules actually require, does step 3
    (stripping the finalizer by hand) leave the claim's IP block released or leaked, and is
    `make jit-down` in step 4 safe to run when a workspace is still wedged? Judge the README's own
    rule — "a destroy that fails for the same reason twice is a design problem wearing an
    implementation costume" — against the three destroy defects this step fixed.

12. This is the last step in the plan. For each item in the build plan's "Done" list, say whether
    S17 leaves it satisfied or open — in particular "docs/todo.md boxes all ticked" (S-1's box is
    unticked and the review boxes for S8-S16 were not touched), "`make all` and `make jit-verify` both
    green from a cold `make destroy`" (not run in this step; a cold destroy is the one path J1's fix
    does not exercise), and "a short note on what production needs that this omits". Then answer the
    design note's own open questions where this step has effectively decided them: annotation edited
    on a live Deployment, visibility of `Orphaned` infra, and IP-block reuse.

13. Write docs/reviews/S17-findings.md with CLEAR / BLOCKED / CONCERNS.

There is no step after S17. Do not start anything new; report the findings.
