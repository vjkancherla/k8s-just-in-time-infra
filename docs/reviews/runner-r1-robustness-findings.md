# runner robustness review (071dd24..6105ce2)

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: CONCERNS

Prompt integrity: `docs/reviews/runner-r1-robustness-review-prompt.md` carries all twelve
numbered questions. Range is one commit (`6105ce2`, parent `071dd24`) touching exactly
`jit-runner/main.py` (+76/-16), `docs/evidence/S24.log` (+2/-2), `docs/evidence/S27.log`
(+2/-2). The container's `/opt/jit-runner/main.py` md5 `dcb9ffdb137f607629705899c380a757`
is byte-identical to the committed file, so both checkpoints and every probe below
exercised the reviewed code, not a stale image.

## Blockers

None.

1. No mechanical finding (Q1-Q5): nothing under `scripts/checks/`, `.clinerules/`, CI or
   scanner config is touched; the only added import is `re` (stdlib, not a dependency);
   no test or assertion is deleted or weakened - the evidence logs' raw output is
   byte-identical to the captures they replaced (only the `started`/`commit`/`pending`
   header lines differ, `git diff a374e21..6105ce2 -- docs/evidence/S*.log` = `+6 -6`);
   no file outside the allowed three appears in the range; `docs/todo.md` is untouched.
   No file under `scripts/checks/` or `scripts/checkpoint.sh` was amended, so there is no
   ADR under review.
2. Both checkpoints pass on my clean runs (Q6) - see Checkpoint assessment.
3. No design disagreement: ADR 0023's runner bullet and `docs/HANDOFF.md` P0.2 name all
   four items verbatim ("Make a failed read refuse, not proceed", "misses
   wrapped/qualified addresses", "a failed removal is silent and never retried",
   "`except Exception` doesn't catch `asyncio.CancelledError`"), and the diff implements
   exactly those four, nothing else.
4. The blind-checkpoint judgement call is recorded as Concern 1, not a blocker: the step
   claimed no assertion for these fixes (commit message asserts only behaviours), so per
   the prompt's verdict rules it is a Concern.

## Concerns

1. **Both checkpoints are blind to all four fixes - and the committed evidence proves it
   by being unchanged.** S24 asserts the params-keyed cache, the changed-params re-apply,
   `/tmp/jit-s24-check-*` dir counts (1 then 0), no `state rm` for redis-only state, and
   `state rm` for the injected address `postgresql_database.voting`; S27 asserts in-place
   database adds, volume survival and a clean destroy. None of them can fail because of
   this range: every `state list` those scripts drive succeeds (rc 0), so the refuse
   branch (main.py:531-546) is never entered; the injected address is root-level and
   matched identically by the old `startswith("postgresql_")` filter and the new regex
   (main.py:75), so item 2 is not discriminated; `ignore_errors=True` and `_rmtree` are
   behaviourally indistinguishable to those scripts; nothing cancels a handler. The
   hard evidence: the raw output of both committed logs is byte-identical to the pre-fix
   captures (the diff is headers only), so deleting the whole patch would print the same
   PASS lines. The implementer's discriminating probe is a monkeypatch run outside the
   checkpoints (reproduced below); it is not committed anywhere. Remedy if the next step
   wants a gate: a checkpoint assertion that a failing `state list` refuses, and one that
   a module-qualified address reaches `state rm`.

2. **Item 1 is a case-sensitive substring test over an unstructured, ANSI-encoded vendor
   error string, and it fails open.** `"No state file was found" not in state.stderr`
   (main.py:539) decides between "empty workspace, proceed" and "refuse". I verified the
   split against the real OpenTofu v1.8.1 in the running container, and today it is
   correct: a cold key gives rc 1 with `ESC[31mNo state file was found!` (phrase
   contiguous after the colour prefix) → proceed, and a real `tofu destroy` on that empty
   state returns rc 0 (`No changes... Destroy complete!`), so the comment's "harmless
   no-op" is true and a never-applied workspace still returns `destroyed`; a genuinely
   unreadable state gives `Error loading the state: operation error S3: ... connection
   refused` (no phrase) → refuse, and a lost `.terraform` gives `Backend initialization
   required` → refuse; bad credentials are caught one step earlier, because `tofu init`
   fails with the S3 403 and init and `state list` share the same env and backend-config.
   What I would attack: (a) any failure whose stderr *embeds* the phrase is treated as an
   empty workspace - demonstrated, `'AccessDenied: ... (No state file was found?)'` and
   `'Error: failed to read state: No state file was found'` both return `destroyed`; (b)
   the match is case- and wording-sensitive, so `'no state file was found!'` refuses -
   an OpenTofu bump in a future `make jit-up` that rewords or re-cases the message turns
   *every* cold destroy into a hard refusal, and no checkpoint pins that path (S24/S27
   never destroy an unapplied workspace; S14:67's setup DELETE is `|| true` and outside
   my run scope). Suggest at minimum documenting the pinned OpenTofu version next to the
   string, or matching on a stable prefix after stripping ANSI (`_strip_ansi` already
   exists at main.py:215 and is not used here).

3. **Item 2's regex widens the match into a class the old filter excluded.**
   `(?:^|\.)postgresql_[A-Za-z0-9_]+\.` (main.py:75) puts the type segment in a position
   that is indistinguishable from a *name* segment: it matches the intended addresses
   (verified: `postgresql_database.this`, `postgresql_database.this["voting"]` - the
   module's real `for_each` address, `module.pg.postgresql_database.this`,
   `module.a.module.b.postgresql_database.x`, and the S24-injected
   `postgresql_database.voting`), but also `docker_container.postgresql_mirror.x`,
   `aws_s3_bucket.postgresql_backups.x` and `data.postgresql_database.this` - the first
   two would be dropped from state before destroy and their real resources orphaned,
   which is the exact failure S24 guards against, in mirror image, and which the old
   `startswith("postgresql_")` filter could not produce. It is latent, not active: a
   grep of `jit-modules/` shows resource names `this`, `postgres`, `postgres_data`,
   `redis`, `pgadmin`, `pgadmin_servers` only, no `postgresql_*`-named resource of any
   type and no postgresql data source, and the runner deploys each module directory as
   the root module (no `module` blocks anywhere), so today's real addresses are all
   `postgresql_database.this["..."]`. The code comment also says "the type segment of a
   managed resource", which the `data.` match contradicts. Ask for an anchor on the type
   position (e.g. `^(?:module\.[^.]+\.)*postgresql_[^.]+\.`) so only a type segment
   matches. `state rm` does receive exactly `line.strip()` of each matching line - the
   test and the value use the same expression - so addresses are not re-formatted.

4. **Item 4's cleanup races the tofu thread it cannot stop.** The handlers themselves are
   right (Q11 detail in Notes): both re-raise, the `_apply_run` comment's invariant is
   literally true - main.py:389-402 has no `await` (`_runs_lock` is a `threading.Lock`),
   so a cancellation can only land at 351/369/380, before the swap, which makes removing
   `work_dir` cache-safe - and `delete_run`'s `if not cached` (main.py:586) is correct
   because `cached` is fixed at 475 and the fresh dir is created at 479, before the first
   await at 505. What is not safe is the directory's *contents*: cancelling an
   `await asyncio.to_thread(...)` does not stop the thread. Demonstrated with the same
   shape as `_run_tofu`: the handler's `rmtree` runs while the worker is still running,
   then the worker runs to completion against a cwd that no longer exists. So on every
   cancellation during a tofu call - which is where cancellation actually lands - the new
   code deletes the work dir out from under a live `tofu` process that may run for up to
   600 s. Consequences are bounded but real: a cancelled `tofu apply` can fail mid-flight
   and leave containers/volumes with no `_runs` entry (the infra-orphan risk is
   pre-existing and unchanged - no entry ever existed), `_rmtree` may log a partial
   removal, and a cancelled *cached* destroy leaves an orphaned background destroy that a
   retry can race (also pre-existing - the new handler changes nothing for cached runs).
   The comment "removing this call's own dir is always safe" is true w.r.t. the cache and
   silent about the thread; it should say which it means, or the handler should await the
   worker (or cancel the subprocess) before removing. Note also that starlette does not
   cancel a handler on client disconnect by default, so these paths fire mainly on server
   shutdown (`make jit-up`) - the pre-existing review called this informational, and it
   still is.

## Notes

- **Q8/Q9 reproduction and attack of the implementer's probe.** Re-run inside the
  container against the reviewed code (`delete_run` with `main._run_tofu_async`
  monkeypatched): `'connection refused'` → `error` containing `refusing to destroy on an
  unreadable state`; `'No state file was found!'` → `destroyed`; the real ANSI form
  `ESC[31mNo state file was found!ESC[0m` → `destroyed`. Attacks as listed in Concern 2.
  Because the probe fakes stderr it proves branch logic only; the real-string
  verification against OpenTofu 1.8.1 is mine and is described in Concern 2.
- **Q10 (`_rmtree`) holds.** `if not path` guards `None`/empty; `FileNotFoundError` is
  caught before `OSError`, and `PermissionError`/`NotADirectoryError`/"Cannot call rmtree
  on a symbolic link" are all `OSError` subclasses, so it never raises from any of the 15
  call sites. No `ignore_errors=` call remains in code (only in the docstring quotes).
  Every new call site sits behind the same guard as its siblings (`if not cached` in the
  refuse branch, main.py:540; `if not cached` in the destroy cancel handler, 586), so no
  path removes a directory a retry needs. One thing it does *not* do, and the debt wording
  asks for: "never retried" is unchanged - a logged removal failure is visible in `docker
  logs` and nothing ever re-attempts it.
- **Q11 coverage sweep.** All `await` sites enumerated: `to_thread` (209), the seven
  `_run_tofu_async` calls (351, 369, 380 in `_apply_run`; 505, 530, 560, 569 in
  `delete_run`) - all inside `try`; `await _apply_run` (332) has no dir at risk;
  `async with _run_lock` (324, 448) precedes any dir for that call. `tempfile.mkdtemp`
  sits outside the `try` at 337 but no `await` precedes it inside its coroutine, so it
  cannot be skipped by cancellation (a future edit inserting an await before line 337
  would create an uncovered path - the invariant is real but unenforced). The remaining
  uncovered point is the orphaned thread, Concern 4.
- **Probe residue I left in the shared MinIO bucket** (disclosed, not cleaned - I may not
  modify anything): my real `tofu destroy` cold-path test wrote one empty state object at
  `s3://jit-state/ns/review-coldprobe/redis/terraform.tfstate`. Nothing references that
  key. Remove with `aws s3 rm --endpoint-url http://172.19.0.11:9000
  s3://jit-state/ns/review-coldprobe/redis/terraform.tfstate`. My other probe keys
  (`review-probe-nonexist`, `review-unreadprobe`, `rev-cold2`, `rev-probe-ws`) have no
  object; no probe containers, volumes or work dirs remain (`ls /tmp | grep -c '^jit-'`
  in the container → 0), and my two checkpoint runs left no `s24-*`/`s27-*` residue.
- **`docs/HANDOFF.md` is untracked and now stale.** P0.2 still lists all of its bullets as
  open, including the four fixed here; the remaining P0.2 items (`runner-api.md` stale,
  runner-restart orphaned dirs, ADR 0023 wording annotation) are untouched by the range,
  correctly - they were not in scope. The untracked status also means "named verbatim in
  HANDOFF P0.2" is verifiable only from the working tree, not from git history.
- The committed evidence headers read `commit 071dd24 / pending 2` (S24) and
  `pending 3` (S27) - the standard capture-then-commit-in-the-same-commit flow, and the
  counts differ only because the tree changed between 14:38:48Z and 14:39:15Z.
- Out of prompt scope, not run: `make jit-verify`, the J-suite, and S06/S07/S14. The
  response contract, param encoding and cache check are untouched, so the `params: {}`
  flows are unaffected; S14's setup DELETE (S14.sh:67) is the one place that may drive a
  cold destroy through the new branch, and it is `|| true`.
- Pre-existing, unchanged by this range and noted only because the new refuse message
  inherits it: API `error` strings embed raw stderr including ANSI escapes (e.g.
  `refusing to destroy on an unreadable state: ESC[31m...`), and `_get_outputs`
  (main.py:294) still runs `tofu output` synchronously on the event loop for up to 600 s.
- **Q12 maintainability:** yes - each of the four blocks quotes the debt wording at the
  decision point, `_rmtree`'s docstring argues why log-not-raise, and the state-list
  comment walks the empty-vs-unreadable distinction, so intent is recoverable cold.

## Checkpoint assessment

`scripts/checkpoint.sh 24 /tmp/S24-review.log` and `scripts/checkpoint.sh 27
/tmp/S27-review.log` both PASS on my runs: S24 `PASS S24: cache keyed on params; changed
params re-apply; state rm conditional on postgresql_* in state; volume goes with its
container`, header `commit 6105ce2 / pending 0`, exit 0, started 14:41:45Z; S27
`2 ok ... 3 ok ... 4 ok ... PASS S27: postgres in place, volume-surviving replaces,
service_url_<db>, clean destroy`, header `commit 6105ce2 / pending 0`, exit 0, started
14:42:16Z. Both are clean runs of the reviewed range, so the implementer's passes are not
leftover state, and neither is a frozen-checkpoint amendment, so there is no ADR to
judge. They assert none of the four fixes and would pass with the entire patch reverted:
the refuse branch is never entered (every driven `state list` returns rc 0), the filter
change is not discriminated (S24 injects a root-level address both filters match),
`_rmtree` and `ignore_errors=True` behave identically to them, and no handler is
cancelled - proven rather than argued, since both logs' raw output is byte-identical to
their pre-fix captures. The step made no claim that these checkpoints assert the fixes,
so per the verdict rules this is Concern 1, not a blocker; the discriminating evidence
for the range is the implementer's monkeypatch probe (reproduced and attacked in Notes)
plus this review's real-OpenTofu measurements, none of which is committed.

Verdict: CONCERNS
