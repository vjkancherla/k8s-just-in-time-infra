# S26 Review

Reviewer model: deepseek-v4-pro (opencode-go/deepseek-v4-pro)
Verdict: CONCERNS

Prompt intact: yes — twelve numbered questions, counted. Range `dd49333..eecc583` =
11 commits, 10 files (the three implementation files, `docs/evidence/S26.log`,
`scripts/checks/S26.sh`, ADRs 0012/0013/0014, and the two exempt review-machinery
files). The prior BLOCKED review's single blocker (postgres `databases` removal never
refused) is resolved by `eecc583`, verified below.

## Blockers

None.

The one blocker the prior review raised is fixed. `_normalize_params` no longer
stringifies lists/objects (`jit-controller/main.py:664-680`): it now preserves
list/object shape and stringifies only scalars, so `status.appliedParams` stores
`databases` as a list and `validate_params`' removal guard
(`isinstance(old, list)`, `main.py:768-772`) can fire. I reproduced the stored-form
path against the fixed code:

```
stored appliedParams: {'databases': ['voting', 'analytics']} list
removal check ok: False key: databases reason: removing database analytics is refused
```

and `reconcile_claim` now feeds `validate_params` the normalized desired
(`main.py:970`), so the list never re-stringifies on the way in. The regression test
was also corrected to pass the normalized stored form
(`test_declarers.py:126-143`), so the dead-guard masking the prior review caught is
gone. `eecc583` additionally resolves the prior review's concerns 2 (backfill now
adopts the pre-projection `spec.params`, `main.py:940-954`) and 4 (uses
`resolve_desired`'s normalized value instead of re-deriving a raw one, `main.py:935`).

## Concerns

1. **Backfill is a load-bearing safety property that neither the checkpoint nor the
   unit suite exercises, and ADR 0012 claims the opposite.** The design is explicit —
   "without this, the first resync after the upgrade would replace every Redis"
   (`declarers-and-consumers.md:143`) — and the build plan's S26 checkpoint description
   lists "the backfill" among what the checkpoint asserts (`build-plan.md:951`). But
   `scripts/checks/S26.sh` has no group that seeds a `Ready` claim with no
   `appliedParams` and asserts the adoption; the frozen script only ever provisions
   fresh claims, which always write `appliedParams`, so the backfill branch
   (`main.py:947-958`) is never taken in S26. It is also not unit-tested:
   `test_declarers.py` imports only `_normalize_params, params_hash, resolve_desired,
   validate_params` (`:19`) and has no test of `reconcile_claim`. ADR 0012's "Not in
   scope" line — "the implementation's unit tests cover both" backfill and
   new-declarer-after-a-gap (`0012-s26-checkpoint-harness-fixes.md:148-149`) — is false
   on its face. The property is live-gated only by S29/U11. Acceptable only because the
   prompt and ADR 0012 explicitly defer it; flag it so it is not assumed covered.

2. **Design rule 3's "on a new claim, first-writer-wins stays as today" is only
   emergent, not implemented.** `reconcile_claim` resolves from *live* Deployments
   (`_reference_declarers`, `main.py:683-702`), so when two disagreeing declarers are
   applied together on a fresh namespace (one `kubectl apply -f` carrying both), the
   first reconcile already sees both, resolves a conflict, and `return`s
   (`main.py:925-928`) before provisioning — the claim sits in phase `""`, never
   `Pending` or `Ready`. Sequentially applied declarers work (the first provisions,
   the second conflicts), and "first" is ill-defined for a truly simultaneous apply,
   but the design's "create behaviour is unchanged" line is not actually honoured for
   that case. The checkpoint's own group 1→2 order hides it. Edge, not blocker.

3. **`softDeleteTTL` maximum resolution (design rule 7) is absent from this step.**
   `reconcile_claim` never touches TTL, and `spec.softDeleteTTL` is taken once from the
   creating event (`main.py:158`). §Resolution rules is on S26's Read list, so this is
   flagged so rule 7 is not silently dropped before S28/S29 (asserted by U13).

4. **`_reference_declarers` duplicates `list_referencing_deployments_with_params`.**
   `main.py:641-656` and `:683-702` both list Deployments annotating
   `jit.infra/<module>` and differ only in whether they return the `declares` flag; the
   former is now used only by `list_referencing_deployments` for the resync orphan
   check. Two near-identical list-and-parse paths are a drift risk for whoever next
   edits the role rule (the `params`-key-presence test lives in both, subtly).

5. **A refused edit still projects the invalid value onto `spec.params` before it is
   rejected.** `reconcile_claim` projects the agreed desired at `main.py:941`, before
   `validate_params` at `main.py:970`. So `maxmemory: banana` lands in `spec.params`
   while `appliedParams` holds the last good value and `UpdateRefused=True` — a
   consumer reading `spec.params` sees the invalid desired until the next agreeing edit
   nulls it via `_project_spec_params`'s `{k: None}` removal. Defensible (the design
   defines `spec.params` as "desired projected"), but worth a comment in the code that
   the projection is intentionally ahead of the contract, since the `_destroy_params`
   comment already documents the inverse hazard on the teardown side.

## Notes

- ADR 0012 is a sound harness fix, judged as a decision not a violation: the six
  reproduced defects are real against the current tree, and each amendment corrects a
  locator/setup without changing an `ok:` line or failure message. ADR 0013 (second
  scratch namespace) is also sound — a namespace-scoped watch genuinely does not run
  the claim's delete handler while the namespace terminates, so recreating the first
  namespace hangs on the finalizer. Both are committed with their edits, and the later
  `eecc583` touches no checkpoint.
- ADR 0014 (executor-pool) is coherent, judged as a decision: kopf runs the sync
  handler off the event loop, so the design's `asyncio.to_thread` remedy applies only
  to an async handler; the 6-worker ceiling is reached only by six concurrent 600s
  applies, which a six-claim demo with per-claim locking does not reach. Recording the
  bound rather than converting handlers stays out of the step's named Do list.
- Mechanical items 1-5 are clean: only `scripts/checks/S26.sh` under a frozen path and
  it is sanctioned by ADR 0012/0013; no new third-party dependency (`hashlib` and the
  stub's stdlib `http.server`/`threading` are stdlib); no existing test deleted or
  weakened (`check_param_conflict` had no test of its own and its removal is the
  design's required replacement); no implementation file outside the list; `docs/todo.md`
  S26 boxes are both still unchecked.
- The runner's `_var_args` (`jit-runner/main.py:133-146`) already JSON-encodes lists
  and objects, so the controller's fix — `call_runner`/`destroy_infra` now send
  structured values instead of their Python repr — aligns with the existing runner,
  not against it. That file is outside the reviewed range and was not changed here.
- The committed evidence header names `commit e6a6a14` with `2 uncommitted change(s)`:
  the log was captured while the `eecc583` fix was still uncommitted in the working
  tree (main.py + test_declarers.py). The substantive content is identical to my clean
  run, but the committed log's metadata does not cleanly name the commit whose code it
  tested. Evidence hygiene, not a defect.

## Checkpoint assessment

`scripts/checkpoint.sh 26 /tmp/S26-review.log` passed on my clean run — commit
`41666e2`, zero pending changes, all nine groups `ok`, `PASS S26: nine
resolution/contract/flow groups asserted against the stub`, exit 0 — with the cluster
and CRD up. It asserts the step's core redis-path goal: declarer resolution
(`spec.params` projected, `declaredBy`), `ParamsConflict` among declarers with no
runner call, refusal of a bad value and an unknown key with no POST, a real update
reaching the stub with `appliedParams`/`attemptedParamsHash`/`Updating`, the failure
branch keeping `Ready` with one attempt then retry-on-change, `NoDeclarer`,
`AwaitingDeclarer` on a consumer-only claim, and stale-`Updating` recovery. Each group
reads a named condition or spec/status field, and the call-count guards can only be
non-zero for a controller that really POSTs, so it would fail with the
resolution/contract/update/recovery logic removed. It does **not** assert backfill, the
new-declarer-after-a-gap path, or any postgres behaviour — which is where Concerns 1
and 2 live, invisible to this frozen redis-only gate.

Verdict: CONCERNS
