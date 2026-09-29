# Session debt cumulative review (a374e21..426af56, main)

Reviewer model: opencode-go/mimo-v2.6-flash
Range: `a374e21..HEAD` = 16 commits (`f8bf679` … `426af56`), read-only inspection plus
`python3 -m py_compile` on both `main.py` files (clean). S18, S26, S27 and S29 were **not**
run (live stack; the brief forbids it), so no checkpoint passed on *my* run and CLEAR is
unavailable by the verdict rules.

## Blockers

None.

1. Mechanical checks 1-5: `git diff --stat a374e21..HEAD -- scripts/` is exactly
   `scripts/checks/S18.sh`, `S25.sh`, `S29.sh` — three frozen-checkpoint edits, and each is
   committed **with** its ADR in the same commit (`e1e2006`+0028, `9bffd7e`+0027,
   `87c0407`+0026), which is the sanctioned path; `scripts/checkpoint.sh` is untouched. No
   dependency added (both diffs use stdlib only: `re`, `contextlib.asynccontextmanager`).
   No file outside the session's declared scope was created; `docs/todo.md` was not ticked.
2. No assertion was deleted or silently weakened: S25 gained two assertions (condition-list
   cross-check, status restore), S29's U13 lost its `|| true` (strictly stronger), and S18's
   redis assertion was *inverted* — sanctioned by ADR 0028, whose premise I verified
   (`Makefile:99` `demo-undeploy` deletes all three Deployments; the old "worker still
   references it" message is a leftover from the pre-rename `demo-soft` behaviour).
3. `python3 -m py_compile jit-controller/main.py jit-runner/main.py` passes; `git status`
   at HEAD is clean apart from the pre-existing untracked `docs/HANDOFF.md`.

## Concerns

1. **ADR 0025's safety claim is false for the very path it is about; C1 concern 5 was not
   actually closed.** `docs/decisions/0025-create-validation-and-nested-clear.md:57-59`
   (added by `a0b1f95`, whose message claims "C1 concerns 3-5") states: "A refused create
   projects nothing onto `spec.params`, so teardown's `appliedParams or spec.params`
   fallback cannot send the refused key to the module (which would fail the destroy and
   retry every tick)." It can: `ensure_claim` seeds `spec.params` from the annotation at
   claim creation (`jit-controller/main.py:154-160`, body `"spec": spec` at `:210`) *before*
   `reconcile_claim` validates, a refusal returns at `:1110-1113` without touching
   `spec.params`, no `appliedParams` is ever written for a never-provisioned claim, and
   `_destroy_params` (`:959`) then returns `spec.params` — the refused key — to the runner.
   The resync orphans a never-provisioned claim (`:1400-1411`), the TTL sweep calls
   `destroy_infra` with it (`:1442`), the destroy fails, and the claim retries forever with
   `release_block` never running. This is *exactly* the path C1 concern 5 named (it even
   cited `main.py:157`); moving the projection after validation fixes only the case where
   `spec.params` was clean, and `appliedParams` being present — which is what saved the
   update path — never happens on create. `a0b1f95` is also the one commit in the range that
   no review covered (C1 reviewed `b4e7a7c`, not the response). Not a regression: pre-range
   the same typo'd create ended identically via a poisoned `appliedParams`, so C1's
   "severity is unchanged" still holds — but the ADR now asserts a protection the code does
   not have, and no gate can catch it (`scripts/checks/S26.sh:115-123` is update-only).
   **Actionable:** either correct the Consequences bullet to describe the real end-of-life
   (stuck `Deleting`, IP block held until the annotation is fixed), or close the path —
   project the last *accepted* params (or `{}`) on refusal, or skip the `spec.params`
   fallback when the claim never provisioned.
2. **S18's amended gate has no evidence anywhere.** `docs/evidence/S18.log` does not exist
   at any revision (`git show HEAD:docs/evidence/S18.log` → path does not exist), and
   `scripts/checks/S18.sh` was last edited by `e1e2006` with no run after it — the range
   contains no run of the amended assertion. ADR 0028 discloses this honestly
   (`:40-44`) and records the human's direction to stop paying the bring-up cost, and
   `memory-bank/activeContext.md:59` repeats it, so I am not calling it a blocker — but the
   ADR also promises "a reader of `docs/todo.md` should treat S18's box as
   corrected-but-not-reconfirmed", and `docs/todo.md:93` still reads a bare
   `- [x] check  - [x] review  **S18**` with no such marker (todo.md untouched in the
   range). The tracker therefore still asserts a check that has never passed against the
   current script. **Actionable:** run `scripts/checkpoint.sh 18` at the next `make
   demo-up`, or annotate the box now.
3. **ADR 0027 claims the two condition lists "cannot drift"; the assertion is
   one-directional.** `scripts/checks/S25.sh:21-27` asserts CRD ⊆ controller (every CRD
   enum name appears quoted in `jit-controller/main.py`) and nothing else. The direction
   that reproduces the failure ADR 0027 exists for is the converse: a type added to
   `_CONDITION_TYPES` but not to `deploy/crd/infraclaim.yaml:70-77` passes the guard and
   then makes the API server reject the whole conditions array — the swallowed-`ApiException`
   the ADR describes. `docs/decisions/0027-...md:31-32` promises more than
   `S25.sh` delivers. **Actionable:** add the converse check (grep every entry of
   `_CONDITION_TYPES` for the enum in the CRD), one line.
4. **The final controller code has never been through S26 or S29, and memory-bank says it
   has.** `9bffd7e` changed `jit-controller/main.py` (added `_CONDITION_TYPES` and the
   `set_condition` guard) *after* the last S26 run (`a0b1f95`, evidence committed with it)
   and after the last S29 run (`87c0407`/`e1191ea`); S24/S27 headers name `a1523be`.
   `memory-bank/activeContext.md:40` says "S24, S25, S26, S27, S29 all PASS on the current
   tree", which is true only for S25. Risk is low and I checked why: `_CONDITION_TYPES`
   (`main.py:764-767`) equals the CRD enum (`deploy/crd/infraclaim.yaml:70-77`) equals the
   seven literals used at all 24 `set_condition` call sites, and only `set_condition`
   (`:1176`) and `clear_condition` (`:1193`) ever write `status.conditions` — so the guard
   is inert today and cannot drop a valid write. The claim is still wrong as written.
5. **S25's cleanup does not run on the failure path.** `scripts/checks/S25.sh:8` `fail()`
   is `exit 1`, and the restore block (`:57-69`) sits after the probe assertions (`:50-53`).
   Any assertion failure between the probe and the restore leaves `appliedParams={"probe":
   "s25"}`, `attemptedParamsHash="s25-probe-hash"` and `declaredBy=["probe-s25"]` on a live
   claim — precisely the residue ADR 0027 exists to prevent, on the run where someone is
   already debugging. Secondary: `declaredBy` restores `status.get("declaredBy", [])`
   (`:63`), so a claim that had no `declaredBy` key gains `[]`; and the restore reverts any
   status write the controller made in the ~2s window (converges, but it is a revert, not a
   no-op). **Actionable:** `trap` the restore so it runs on failure too.
6. **ADR 0023's closure note was never amended after R1/R2 came back.**
   `docs/decisions/0023-stage-h-concerns-accepted.md:48-55` still opens "All five
   sub-defects in this bullet are closed" and cites the two review files by name, while
   `runner-r2-ops-review-findings.md` concern 1 shows the `state list` phrase test now
   *fails open wider* (`jit-runner/main.py:577-578` includes `state.stdout` in the haystack,
   so a stdout carrying "no state file was found" plus a real stderr error proceeds as an
   empty workspace and can destroy past an unreadable state) and concern 5 shows the note's
   own count is wrong. Neither is fixed in the range; `memory-bank/activeContext.md:56-58`
   does list r2-concern-1 as accepted debt, but a reader of the ADR alone is told the risk
   is closed. **Actionable:** append one sentence to the status note.
7. **New (none of the four in-range reviews measured it): the controller's destroy timeout
   is now shorter than the queue the new lock can put it in.** `jit-controller/main.py:1256`
   uses `requests.delete(..., timeout=120)` while apply uses `timeout=600` (`:554`); after
   `f8bf679` a DELETE waits on `_run_lock(key)` behind an in-flight apply for the same
   `(workspace, module)`. An apply longer than 120s makes the client time out while the
   server-side destroy is still queued, so the handler reports failure and retries —
   convergent (a later cold destroy sees "no state file was found" and succeeds), but each
   teardown behind a long apply can cost several 120s cycles and the retry itself blocks
   behind the first destroy. `grep` over the four findings files finds no mention of 120.
   **Actionable:** one line — raise the DELETE timeout above the apply timeout, or document
   the retry cost.
8. **`docs/HANDOFF.md` is untracked while four ADRs and the memory-bank cite it as the debt
   list.** `git status --porcelain` → `?? docs/HANDOFF.md`; ADR 0023/0025/0027/0028 and
   `memory-bank/*` quote "HANDOFF P0.1-P0.6/P1" as their authority. A fresh clone has no
   such file, so every citation dangles. Disclosed at `activeContext.md:51`, but the
   citations are in committed files.
9. **Scope fence: two files under `docs/designs/` were edited.** The S22 rules allow
   `docs/designs/` only "where step S28 names the exact amendments"; S28 named neither
   (`runner-api.md` +24/-6, `declarers-and-consumers.md` 1/-1 in `d917804`/`08ec92c`).
   Authority actually rests on ADR 0016, which says in as many words "The design's
   `for_each` + import line is superseded for this module", and on ADR 0023's accepted-debt
   bullet ("`runner-api.md` documents neither the params-keyed cache nor the destroy-params
   type"). I verified both edits against the code and they are accurate (`status:
   "success"` matches `RunResponse`, the cache/lock/`state rm`/sweep paragraphs match
   `jit-runner/main.py`) — so this is a citation-of-authority note, not a content defect,
   but the carve-out used is the ADR path, not the one the rule names.
10. **No review prompt in the range cites ADRs 0026-0028.** The rule is "committed with the
    edit and cited in the review prompt"; `S18/S25/S29-review-prompt.md` are untouched and
    predate the amendments, so the first assessment of all three ADRs is this review. The
    ADRs themselves are committed with their edits (verified above).

## Notes

- **"B25":** nothing named `B25` exists in the range or the repo (`grep -rn B25 docs/
  scripts/ .opencode/` → nothing); no `scripts/checks/B25.sh`. I read the brief's
  "S18/S25/S29/B25 checkpoint edits" as the S18/S25/S29 amendments plus ADR 0025 (the
  controller create-validation/nested-clear decision, which touches no checkpoint). If B25
  names something else, it is outside this range.
- **Evidence hygiene is good.** Every `docs/evidence/S*.log` diff in the range is header
  lines only (`started`/`commit`/`pending`); the raw output below the "do not edit" marker
  is byte-identical to what it replaced, i.e. all re-runs were produced by
  `scripts/checkpoint.sh`, never hand-edited. The `pending` counts are consistent with the
  trees (e.g. S24's 4 = runner `main.py` + `runner-api.md` + ADR 0023 + S27.log).
- **Evidence-after-amendment is structurally forced, not a violation.**
  `scripts/checkpoint.sh:27-33` refuses to run when the check file has uncommitted changes,
  so an amended checkpoint's log can only be committed *after* the amendment commit:
  `9bffd7e → 017bce0` (S25) and `87c0407 → e1191ea` (S29) match the pre-range pattern
  `89d4a27 → a374e21` (ADR 0024 → S24 evidence). S24/S26/S27 evidence was committed in the
  same commit as its code, as the rule asks. The only evidence gap is S18 (concern 2).
- **ADR 0026's premise checks out.** `app/kustomize/base/{worker,result}-deployment.yaml`
  pin both `voting-b-postgres` references to `softDeleteTTL: "10m"`, `vote-deployment.yaml`
  carries no `jit.infra/postgres` annotation, and U13's extra annotation only names `redis`
  — so `voting-b-postgres` must be `10m` while `voting-b-redis` must be `45m`. The S29 log
  after the amendment still ends `U13 ok … PASS S29: U1-U13 asserted live`, `# exit 0`,
  `pending 0` (clean tree).
- **ADR 0028's premise checks out.** `Makefile:99` deletes `voting-app-vote
  voting-app-worker voting-app-result`, so after undeploy every reference is gone and every
  claim (redis included) must go `Orphaned` while the three containers keep running —
  which is what the amended lines `S18.sh:147-150` assert. Residual defect: `S18.sh:151`
  still prints `ok "demo-undeploy orphans with an expiry, keeps redis Ready, destroys
  nothing"`, so the future evidence line will state the opposite of the assertion above it
  (ADR 0028 changed only the fail message).
- **ADR 0027's premise checks out.** CRD enum (`infraclaim.yaml:70-77`) and
  `_CONDITION_TYPES` are the same seven names, all 24 call sites use literals, no other
  writer touches `status.conditions` — the guard cannot misfire today (see concern 3 for
  the direction it does not cover).
- **Runner diff substance verified by reading, not running:** the per-run lock now spans
  resolve+destroy with a re-read inside it; `_PG_RESOURCE_RE` matches flat,
  `for_each["…"]`, `module.pg.` and nested addresses and rejects `data.postgresql_*` /
  `docker_container.postgresql_mirror.*`; the refusal branch distinguishes the pinned
  OpenTofu "no state file was found" message from a real read failure; `CancelledError`
  handlers exist in both `_apply_run` and `delete_run` with `cached`/`work_dir` bound before
  the `try`; `_sweep_orphan_work_dirs` runs in a single-worker uvicorn (`jit-runner/
  Dockerfile:20`, no `--workers`), so it cannot delete a peer worker's live work dir.
  I did not run it.
- **Nothing else in the range regresses observable behaviour** relative to `a374e21`: the
  create-validation and nested-clear changes are covered by the green S26 run at `a0b1f95`
  and the green full S29 gate at `87c0407`; the runner changes are covered by S24/S27.
  The four in-range reviews are all `CONCERNS` with empty Blockers and their prompts carry
  twelve questions; nothing they recorded as a blocker was left unfixed.

## Checkpoint assessment

I ran no checkpoint: S18/S26/S27/S29 need the live stack and the brief forbids it, and per
the verdict rules a CLEAR here would require a checkpoint to pass on my own run, so
CONCERNS is the ceiling. What I could establish without a cluster: the three amended
checkpoints each carry an ADR in the same commit as the edit (`e1e2006`, `9bffd7e`,
`87c0407`); their committed evidence all ends `# exit 0` with a PASS line (S25 at
`9bffd7e` covers the `_CONDITION_TYPES` change, S29 at `87c0407` covers every runner and
controller change up to `a0b1f95`); and I read each amended assertion against its ADR. On
that reading: **ADR 0026 accepted** — the `u13check` rewrite asserts both halves of rule 7
and the green S29 log proves it ran that way, no defect in the assertion. **ADR 0027
accepted with coverage concern 3** — the guard and the restore are correct in substance,
the assertion under-delivers the ADR's "cannot drift" claim and skips its own cleanup on
failure. **ADR 0028 accepted as correct-but-unconfirmed** — the inverted assertion follows
from `Makefile:99` and from the fact that the old message came from the pre-rename soft
path, but no run of it exists anywhere, which the ADR discloses and concern 2 asks to close.
The only defect I would not sign off as written is not a checkpoint at all: ADR 0025's
Consequences bullet (concern 1), which is false for the create path it describes.

Verdict: CONCERNS
