# S26 Review

Reviewer model: deepseek-v4-pro (opencode-go/deepseek-v4-pro)
Verdict: BLOCKED

Prompt intact: yes — twelve numbered questions, counted. Range `dd49333..03bbc96` =
5 commits, 9 files (`jit-controller/main.py`, `jit-controller/stub_runner.py`,
`jit-controller/test_declarers.py`, `docs/evidence/S26.log`, `scripts/checks/S26.sh`,
and ADRs 0012/0013/0014, plus the re-emitted review prompt).

## Blockers

1. **Postgres `databases` removal is never refused — the contract's one safety check is
   dead code, and the unit test masks it.** The design's mutability contract says
   "Additions create databases in place; removals refused"
   (`docs/designs/declarers-and-consumers.md:106`) and U7 asserts `UpdateRefused` on
   removal (`:231`). `validate_params` has the check
   (`jit-controller/main.py:751-755`):

   ```python
   old = applied.get("databases")
   if isinstance(old, list):
       for d in old:
           if d not in dbs:
               return False, "databases", f"removing database {d} is refused"
   ```

   But `applied` comes from `status.appliedParams`, which is written as
   `_normalize_params(...)` output (`main.py:434`, `:919-920`), and `_normalize_params`
   stringifies every value (`main.py:663`):
   `_normalize_params({"databases": ["voting","analytics"]})` →
   `{"databases": "['voting', 'analytics']"}` (a `str`, not a list). So
   `isinstance(old, list)` is always `False` against real stored state and the removal
   branch can never fire. I confirmed it empirically:

   ```
   normalized: {'databases': "['voting', 'analytics']", 'settings': "{'max_connections': '200'}"}
   removal check ok: True key: '' reason: ''
   ```

   A tenant removing a database therefore gets no `UpdateRefused`; the edit proceeds to
   the runner with `databases` as the string `"['voting']"` (and `call_runner` stringifies
   again, `main.py:548`), so U7 in S29 will not refuse, and the module in S27 will see a
   string where it needs a list. The reason this is not caught: `test_declarers.py`
   `test_postgres_database_removal_is_refused` (`:126-132`) passes
   `applied={"databases": ["voting", "analytics"]}` as a *raw list*, not the stringified
   form the controller actually stores — the test is green against an input production
   never produces. `_normalize_params` is used for flat string params (redis `maxmemory`)
   where stringification is a no-op, so S26's redis-only checkpoint cannot see it. This is
   squarely in S26's "Contract + validation" Do list (build plan `:938-941`), and it is a
   design disagreement that changes behaviour.

## Concerns

1. **"First-writer-wins on a new claim" is only emergent, not guaranteed, and the design
   calls it out.** Design rule 3: "On a new claim, first-writer-wins stays as today, so
   create behaviour is unchanged" (`declarers-and-consumers.md:86`). `reconcile_claim`
   resolves from *live* Deployments (`_reference_declarers`, `main.py:872`), not the event
   body. So a fresh namespace where two disagreeing declarers are applied together — e.g.
   one `kubectl apply -f` carrying both — makes the first event's reconcile see both
   declarers already present, resolve a conflict, and `return` before provisioning
   (`main.py:908-911`). The claim is left in an empty phase with `ParamsConflict` and
   never provisions, whereas the design says the first writer's params should be applied.
   Sequential application (the checkpoint's own group 1→2 order) hides this. Not
   exercised by the checkpoint, and a wrong-outcome edge rather than a wrong-state
   transition, so a concern not a blocker — but the design's "create behaviour unchanged"
   line is not actually implemented for the simultaneous case.

2. **Backfill can record the *new* desired params as `appliedParams` without applying
   them.** `reconcile_claim` projects desired onto `spec.params` at `main.py:916`
   (`_project_spec_params`) and only *then* runs the backfill at `main.py:923-932`, which
   adopts `desired_norm` into `appliedParams`. If a declarer's annotation changed during
   the upgrade window (between the old controller's last resync and this one's first),
   `spec.params` has already been overwritten with the new desired, so backfill writes the
   new value as `appliedParams` without a runner call — the container keeps the old params
   while the status claims the new ones, and the `desired == applied` guard (`:934`) then
   stops the update forever. U11 ("No container IDs change; appliedParams backfilled")
   only asserts the no-annotation-change case, so it passes either way. The design's
   backfill text is "adopts its normalized `spec.params`" (`:143`); the intent — don't
   replace every container on upgrade — is met, but the pre-projection read of `spec.params`
   that the wording implies is not what the code does.

3. **ADR 0012's "unit tests cover both" claim is wrong for backfill.** ADR 0012
   "Not in scope" says the new-declarer-after-a-gap path and backfill "the implementation's
   unit tests cover both" (`0012-s26-checkpoint-harness-fixes.md:148-149`), and the review
   prompt's Q7 note repeats "covered by `test_declarers.py`". `test_declarers.py` imports
   only `params_hash, resolve_desired, validate_params` (`:19`) and contains no test of
   `reconcile_claim`, so backfill is *not* unit-tested (verified: no `reconcile_claim`
   import, no `backfill` string). Rule 6 (new declarer after a gap) is covered only as the
   pure `resolve_desired` behaviour, not the stateful "old declarer gone, new one appears"
   scenario. Backfill is a load-bearing safety property ("without this, the first resync
   after upgrade would replace every Redis", `:143`) that is live-gated only by S29/U11.
   The gap is worth recording so it is not assumed covered.

4. **`resolve_desired`'s returned `desired` is a dead variable.** `reconcile_claim`
   assigns `desired, declarers, conflict = resolve_desired(refs)` (`main.py:874`) but then
   recomputes `desired_raw = declarers[0][1] or {}` (`:915`) and re-normalizes
   (`:920`), ignoring the normalized `desired` the function already returned. The result is
   harmless (both normalize identically) but it is the reason `spec.params` is projected
   from a raw form while `appliedParams` is stored normalized, so the two can hold the same
   value with different types (a list vs its stringification). Folding the two call sites
   onto one normalized value would remove the trap that caused Blocker 1.

5. **`_reference_declarers` duplicates `list_referencing_deployments_with_params`.**
   `main.py:638-653` and `:666-685` both list Deployments annotating `jit.infra/<module>`
   and differ only in whether they return the `declares` flag. The old function is now used
   solely by `list_referencing_deployments` for `referencedBy`. Two near-identical
   list-and-parse paths is a drift risk for whoever next edits the role rule; a single
   helper returning `(name, params, declares)` would serve both.

6. **`softDeleteTTL` maximum resolution (design rule 7) is absent from this step.** The
   design says "`softDeleteTTL` is the maximum declared across all references"
   (`declarers-and-consumers.md:90`), asserted by U13 in S29. `reconcile_claim` never
   touches TTL, and `spec.softDeleteTTL` is set once from the creating event
   (`main.py:158`). This is *probably* deferred (S26's Do list omits it, U13 lives in S29),
   but §Resolution rules is on S26's Read list, so flagging that rule 7 is not implemented
   here so it is not silently dropped before S28/S29.

## Notes

- ADR 0012 is a sound harness fix and I judge it as a decision, not a violation: the six
  reproduced defects are real (the `make` `"$@"` bug, the missing `-n "$NS"`, the
  workspace-vs-namespace `stub_get` locator, the groups 5-6 conflict contradiction, the
  `$NS-redis-c2` phantom claim, and the unconfined clusterwide watch are all corroborated
  by the current tree), and each amendment corrects a locator/setup without changing an
  `ok:` line or failure message. Deleting `dnn` between groups 3 and 4 is *necessary* for
  groups 4-6 to test what their messages claim (with `dnn` at 200mb and `d1` edited, a
  correct resolver reports a conflict, not a refusal/update).
- ADR 0013 (second scratch namespace) is also sound: the namespace-scoped watch does not
  run the claim's delete handler while a namespace terminates, so the finalizer hangs the
  recreate; using a pre-created second namespace sidesteps it. The group 8/9 assertions
  are unchanged. Both ADRs are committed with their edits.
- ADR 0014 (executor-pool) is a coherent decision, judged as one: kopf runs the sync
  handler off the event loop, so the design's `asyncio.to_thread` remedy applies only to an
  async handler; the 6-worker bound is reached only by six concurrent 600s applies, which a
  six-claim demo with per-claim locking does not reach. Recording the bound and the two
  options rather than converting handlers is reasonable for a PoC, and it correctly stays
  out of the step's named Do list.
- Mechanical items 1-5 are clean: only `scripts/checks/S26.sh` under a frozen path, and it
  is on the sanctioned list via the ADRs; no new third-party dependency (adds `hashlib`,
  stdlib, and stdlib `http.server`/`threading` in the stub); no existing test deleted or
  weakened (`check_param_conflict` had no test of its own and its removal is the design's
  required replacement); no file outside the list; `docs/todo.md` S26 boxes both still
  unchecked.
- `_recover_stale_updating` (`main.py:831-842`) correctly keys the crash-recovery on
  `claim_lock(...).locked()`: during a real blocking apply the lock is held on the executor
  thread, so the 30s resync's reconcile sees `locked() == True` and does not clear the
  flag; only the seeded/leftover flag (no holder) is cleared. Group 9 exercises exactly
  this and passed.

## Checkpoint assessment

`scripts/checkpoint.sh 26 /tmp/S26-review.log` passed on my clean run — commit `82460cc`,
no pending changes, all nine groups `ok`, `PASS S26: nine resolution/contract/flow groups
asserted against the stub`, exit 0 — with the cluster up (`make jit-up` state) and the CRD
present. It asserts the step's core goal for the redis path: declarer resolution
(`spec.params` projected, `declaredBy`), `ParamsConflict` among declarers with no runner
call, the refusal of a bad value and an unknown key with no POST, a real update reaching
the stub with `appliedParams`/`attemptedParamsHash`/`Updating`, the failure branch keeping
`Ready` with one attempt, `NoDeclarer`, `AwaitingDeclarer` on a consumer-only claim, and
stale-`Updating` recovery. Each group reads a named condition or spec/status field, and the
call-count guards can only be non-zero for a controller that really POSTs. It would fail
with the resolution/contract/update logic removed. It does **not** assert backfill, the
new-declarer-after-a-gap path, or any postgres behaviour — which is exactly where Blocker 1
lives, invisible to this frozen redis-only gate.

Verdict: BLOCKED
