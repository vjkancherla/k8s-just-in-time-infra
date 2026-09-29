# Runner work-dir leak review (`4e0fe8a..7a15db8`)

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Range: one commit, `7a15db8` — `jit-runner/main.py` (+19) and `docs/evidence/S24.log`
(+3/-3). No file under `scripts/checks/` or `scripts/checkpoint.sh` is touched, so there
is no ADR to judge. All five questions in the prompt were checked by reading
`jit-runner/main.py` and by running the code in the live `jit-runner` container (image
built 13:39:28 BST; `/opt/jit-runner/main.py` md5 `2543d8c1…` is identical to the
committed file, so every probe below exercised the reviewed code).

## Blockers

None.

- No mechanical finding: nothing under `scripts/checks/`, `.clinerules/`, CI or scanner
  config; no dependency added (`shutil` already imported, `main.py:14`); no assertion
  deleted or weakened; both files in the range are on the allowed list; `docs/todo.md`
  untouched.
- The checkpoint passes on my clean run (see Checkpoint assessment).
- No design disagreement: nothing in `docs/designs/` prescribes keeping an unreachable
  work dir, and ADR 0023's first debt bullet names exactly this leak.
- The one judgement call — the frozen S24 check does not assert the leak removal — is
  recorded as Concern 1 with its remedy, not as a blocker: this review's evidence bar was
  explicitly "run the checkpoint *and* check for leftover `/tmp/jit-*`", and that second
  half (which the check cannot do) I ran and it passes.

## Concerns

1. **Nothing in the repo asserts this fix, and the evidence committed with it asserts
   nothing either.** `scripts/checks/S24.sh` never inspects `/tmp`: its PASS line covers
   "cache keyed on params; changed params re-apply; state rm conditional; volume", not
   work-dir lifecycle. Delete all 19 added lines and S24 still prints the same PASS with
   exit 0 — proven, not hypothesised: the raw output of `docs/evidence/S24.log` in this
   range is byte-identical to the capture it replaced (the diff is the three header lines
   only, `+3 -3`). Worse, the new capture is *dirtier* than the one it overwrites: header
   reads `commit 4e0fe8a / pending 2 uncommitted change(s)` where the previous capture
   (`3262fbb`) read `pending 0`. One of those two pending files is `jit-runner/main.py`
   itself (mtime 12:38:37Z, run start 12:41:03Z, commit 12:41:36Z); the second is not
   attributable from the range, whose commits carry only `main.py` and the log — so a
   reader cannot tell what else was dirty. **Why it matters:** ADR 0023 calls this leak
   "unbounded disk growth… the first item" of the debt list, and the next edit to
   `main.py` can reintroduce it silently forever. **Remedy:** the repo already has the
   exact pattern — ADR 0010 amended S24 when its cache-hit half "still passes every
   assertion" with the cache deleted. An ADR-backed amendment asserting, after the
   changed-params half, that the workspace has exactly one `/tmp/jit-<ws>-*` dir (i.e. the
   replaced one is gone), or equivalently that the count is unchanged across the second
   POST, closes this. If instead the bar for debt-fix commits is "the committed checkpoint
   must fail when the fix is removed", this concern is a blocker under the step-review
   template's rule 7 — I am recording it as a concern because this prompt paired the
   checkpoint with the `/tmp` check as the evidence route, and the direct check passes.

2. **The new `rmtree(stale_dir)` can pull the floor out from under an in-flight destroy,
   because `delete_run` still takes no lock.** `delete_run` resolves `entry["dir"]` into a
   local `work_dir` at `main.py:407-408` and then runs docker/`tofu init`/`state
   list`/`state rm`/`tofu destroy` across four awaits — holding neither `_run_lock(key)`
   nor any barrier (the "`delete_run` is unlocked" item is itself recorded debt in ADR
   0023 and Concern 6 of the S24 review). Interleaving: destroy resolves cached dir D1 →
   a changed-params POST completes in D2, swaps the entry and `rmtree`s D1
   (`main.py:361-373`) → the destroy's remaining `tofu` calls now execute in a deleted
   directory and fail. Consequences are bounded and retriable — the failure returns at
   `main.py:500-504` do not pop the entry, so `_runs[key]` still points at D2 and a retry
   destroys D2 — but it is a *new* failure mode: before this commit the apply never
   removed anything but its own fresh dir. The mirror interleaving (destroy finishes first
   and pops the entry the apply just replaced, leaking D2) is pre-existing and unchanged
   by this range. **Remedy:** take `_run_lock(key)` for the whole of `delete_run`, the
   recorded debt item; that also fixes the mirror leak.

3. **One unhandled leak path of the same class remains in the function the commit
   edits.** For an uncached destroy the fresh `jit-destroy-*` dir is created at
   `main.py:421` and the module is copied at `main.py:427-428` — both *before* the
   `try:` at `main.py:437`. The module-not-found branch cleans up (`:424`), but any
   `shutil.copy2` `OSError` (ENOSPC, EACCES, source change) escapes the handler as a 500
   and leaks the directory. The commit added `if not cached: rmtree` at the three
   `tofu`-failure returns (`:470`, `:493`, `:501`) but not at the pre-`try` setup.
   Likelihood is low (the three modules are flat, 12-16K — `find` confirms zero
   subdirectories, so `IsADirectoryError` cannot fire today), but it is precisely the
   defect the commit exists to remove. Moving the copy loop inside the `try` closes it.

## Notes

- **Q1 (does the stale dir actually go, and is the locking right?): verified live and
  correct.** POST redis params A → `/tmp/jit-s24rev-rqaylfwt`; POST changed params B →
  the only dir left is `/tmp/jit-s24rev-gyni2hqn`, i.e. the replaced dir was removed by
  the fix; POST B again (identical) → still `gyni2hqn`, no new dir; DELETE → 0 dirs, no
  container, no volume. Locking: `_apply_run` is reachable only from `create_run` inside
  `async with _run_lock(key)` (`main.py:297-305`), so two applies for a key cannot both
  capture the same `previous`; `previous = _runs.get(key)` … swap runs as one atomic
  section under `_runs_lock` (`:362-371`); `rmtree(stale_dir)` happens *after* releasing
  `_runs_lock` (`:372-373`) — correct, it keeps a sync filesystem walk out from under a
  `threading.Lock` that other coroutines block on — while still holding the per-run lock,
  which is the desired serialization. There is no TOCTOU between unlock and `rmtree`:
  nothing ever writes an existing dir back into `_runs` (dirs are only ever assigned at
  `mkdtemp`), so `stale_dir` cannot be re-adopted. The `previous["dir"] != work_dir`
  guard is load-bearing in one corner: if a prior destroy deleted D1 and `mkdtemp`
  happened to reuse the name, the guard prevents the new dir from deleting itself.
- **Q2 (uncached destroy failure cleanup): verified live.** Fresh workspace `s24rev2`,
  no cached entry, destroy forced to fail (`-var 1bad=…` → `Value for undeclared
  variable`) → response `tofu destroy failed`, and the container's `/tmp` jit-dir count
  after was **0**: the `if not cached: rmtree` at `main.py:501-502` fired. The `tofu
  init` (`:470`) and `tofu state rm` (`:493`) branches carry the identical guard and the
  exception path (`:512-513`) already removed the dir unconditionally. Deleting the fresh
  dir loses nothing on retry: for a path-backend run the state lives in MinIO, and a
  retry with no entry builds a fresh dir anyway. The **cached**-failure half ("keep for
  retry") I verified by inspection only — the new lines are guarded by `if not cached`,
  so for a cached run every branch is byte-identical to the pre-commit code; I did not
  sabotage live state to force a cached destroy failure, since the code path is
  unchanged.
- **Q3 (races):** covered as Concern 2 for the apply/destroy pair. Apply/apply on the
  same key is fully serialized; different keys cannot collide (`mkdtemp` names are unique
  and no dir is ever shared between entries — `["dir"]` is read in only two places,
  `main.py:367-368` and `:408`). Two concurrent destroys of one key were already
  unsynchronized before this range and are unchanged.
- **Q4 (no semantic regression): verified live and by reading.** The cache check in
  `create_run` (`main.py:298-304`) is untouched, and a cache hit returns before
  `_apply_run` is ever called, so a hit can neither create nor delete a dir (confirmed:
  identical re-POST left the dir name unchanged). Changed params still run a real apply —
  S24 test 2 asserts the container is replaced and carries `--maxmemory 128mb`, and it
  passed on my run. A **failed** changed-params apply returns at `:340`/`:357` before the
  swap, so the cached entry *and its dir* survive — the fix does not destroy the cache on
  error. Destroy semantics: success still `rmtree` + `_runs.pop` (`:506-508`), verified
  live (0 dirs, container and volume gone); cached failure still keeps the dir (see Q2);
  the exception path (`:512-516`) is untouched.
- **Q5 (leak paths still unhandled):** (a) the pre-`try` copy loop — Concern 3;
  (b) the destroy-wins/pop-replaces-entry leak — Concern 2's mirror half, pre-existing;
  (c) **runner restart orphans everything**: `_runs` is in-memory (`main.py:54`), so a
  `docker start` of a stopped runner (no `--restart` policy is set in
  `deploy/runner.sh:54`) loses every entry while `/tmp` keeps the dirs — bounded in
  practice because `make jit-up` recreates the runner container every time
  (`scripts/jit-up.sh:12,62-63`), but `docker start` alone does not;
  (d) every cleanup uses `ignore_errors=True`, so a failed removal is silent and never
  retried — the entry has already been replaced at that point, so nothing can ever come
  back for it; (e) `except Exception` (`:377`, `:512`) does not catch
  `asyncio.CancelledError`, so a cancelled handler leaks its fresh dir — pre-existing and
  dependent on whether the server cancels handlers, so informational only.
- **ADR 0023 scope:** the commit message says "(ADR 0023 debt 1)". Debt bullet 1 bundles
  *five* defects — the work-dir leak, the silent `state list` skip, the prefix-only
  `postgresql_` filter, the unlocked `delete_run`, and the undocumented `runner-api.md`
  cache/destroy-params. Only the first is fixed here (the other four are untouched by the
  range). A reader tracing "debt 1" from the commit could believe the bullet is closed;
  worth a line wherever the debt list is worked off.
- I did not run `make verify`, `make jit-verify` or the J/R suites (out of scope for this
  prompt). The response contract, param encoding and cache check are untouched, so
  `S06.sh`'s idempotency assertion and the J-suite `params: {}` flows should be
  unaffected.

## Checkpoint assessment

`scripts/checkpoint.sh 24 /tmp/s24-review.log` (private log, committed evidence
untouched) passes on my run: `PASS S24: cache keyed on params; changed params re-apply;
state rm conditional on postgresql_* in state; volume goes with its container`, exit 0,
header `commit 7a15db8 / pending 0` — a clean run against the reviewed range, so the
implementer's pass (captured at `4e0fe8a` with **2 pending changes**) is not
leftover-state, it just says less than it appears to. Leftover check around my run:
`/tmp/jit-*` in the container was **0 before and 0 after** — and that is a discriminating
measurement: S24's step 2 is exactly the changed-params overwrite, and since destroy only
removes the *current* entry's dir, a runner without the fix would end the run with exactly
one orphaned `/tmp/jit-s24-check-*` (≈61 MB). What S24 does *not* do is assert any of
this itself: it would pass with all 19 added lines deleted (the committed log's raw output
is identical pre- and post-fix), so it pins only the no-regression half of this work —
identical params are a cache hit, changed params really re-apply — and the leak-removal
claim rests on this review's `/tmp` probes rather than on a committed assertion
(Concern 1). The destroy-failure and cache-hit halves are covered as noted above; I left
no `s24-*` container, volume or jit directory behind.

Verdict: CONCERNS
