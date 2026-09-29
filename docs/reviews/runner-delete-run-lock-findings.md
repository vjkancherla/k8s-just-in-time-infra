# delete_run lock review (a374e21..f8bf679)

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)

## Blockers

None. Questions 1-5 all came back clean:

1. `git diff a374e21..f8bf679 --name-only` is exactly `docs/evidence/S24.log`,
   `docs/evidence/S27.log`, `jit-runner/main.py`. `--stat` over `scripts/`,
   `.clinerules/`, `.github/`, `docs/todo.md`, `docs/build-plan.md` is empty, so
   `scripts/checks/S24.sh`, `S27.sh`, the CI config and any scanner config are
   byte-unchanged. The single `git diff` hunk in `main.py` is
   `@@ -388,137 +388,149 @@` — `delete_run` only; no import changed.
2. No dependency added (no import touched; the whole diff is inside `delete_run`).
3. No test or assertion deleted or weakened (the two check scripts are absent from the
   range; the "assertion" half of `main.py`, i.e. the `if not cached: rmtree` guards and
   the conditional `state rm`, is byte-identical after de-indentation — see Notes).
4. No file created or edited outside the allowed list. `f8bf679` commits exactly those
   three files.
5. `docs/todo.md` was not touched at all.

## Concerns

1. **Neither checkpoint asserts this step's goal, and both would stay green with the lock
   deleted.** `scripts/checks/S24.sh` and `S27.sh` issue strictly sequential `curl`
   calls (POST…DELETE…POST); nothing overlaps, nothing inspects `_run_locks`, and the only
   `docker logs` greps are for `state rm` (`S24.sh:63,116`). Deleting the
   `async with _run_lock(key):` wrapper and its re-read — leaving every other line as it
   is — would reproduce the identical PASS and exit 0. Per this prompt's verdict rules
   that is a Concern rather than a Blocker, because the step made no claim to the
   contrary: `docs/HANDOFF.md` P0.1 asks only to *run* S24 and S27 as evidence, and
   `docs/decisions/0024-s24-workdir-leak-assertion.md` Consequences states in as many
   words that "The separate `delete_run`-is-unlocked race … is **not** covered by this
   amendment … and it needs its own reviewed step." **Why it still matters:** the debt
   item is now closed by review only, with no regression net — and I found nothing
   anywhere in the repo that exercises concurrency against the runner API (no test uses
   `asyncio.gather`, threads, or overlapping requests). The next edit to `delete_run`
   can drop the lock silently forever, exactly as ADR 0024 described for the leak fix.
   **Actionable if you want it closed:** an ADR-backed amendment that fires a POST and a
   DELETE for the same key concurrently and asserts one of them observes the other's
   result (or a log-line assertion that the destroy resolved "from the cached run" only
   after the apply completed).

2. **`delete_run` is now a second, unbounded creator of `_run_locks` entries.**
   `main.py:414` calls `_run_lock(key)` *before* anything establishes that a run exists:
   the sequence is `key = (workspace, requested)` (392) → `async with _run_lock(key)`
   (414) → first entry lookup (416) → `not_found` return (435). So an authenticated
   `DELETE /v1/runs/{workspace}` carrying any `module` string allocates a permanent
   `asyncio.Lock` in `_run_locks` even when the handler immediately reports
   `not_found`. `_run_locks` is never pruned (`main.py:61-67`), and `_run_locks_guard`
   only guards insertion. This is the same class of growth `create_run:297` already
   causes, so it is not a new defect — but the change widens its surface from one
   endpoint to two, and the growth is driven by caller-supplied strings rather than by
   runs that ever existed. Each object is small; a token holder can still make the count
   unbounded.

3. **Behavioural deltas the task did not mention (question 10).** The task was "take the
   lock"; the diff also restructured key/entry resolution. Enumerating every change
   outside the lock itself:

   - **`elif body and body.module` → `elif requested`, and `module = body.module` →
     `module = requested` (`main.py:425,429`).** Provably equivalent — `requested` is
     truthy only when `body` is non-None and `body.module == requested` — but nothing
     states that proof, and the equivalence breaks the day `requested` is derived any
     other way. *Intended as part of the restructure; acceptable, undocumented.*
   - **The final `else` at `main.py:404-406` is now reachable for exactly one input:
     `body.module == ""`.** Old code reached that same `not_found` by falling through
     after `if requested:` and `if entry is None and requested is None:` both failed;
     new code reaches it via `if requested: … elif requested is None: … else: return`.
     **No behavioural change** (both return `status="not_found"` with the same message,
     for `""` with zero, one or many cached runs). But the branch carries no comment
     saying it exists solely for the empty-module case, and a reader will take it for
     the general "no run found" branch — which is now the *different* return at
     `main.py:435-437`, inside the lock. *Unintended readability regression.*
   - **The no-module fallback's candidate list is snapshotted outside the run lock**
     (`main.py:394-403`), which is unavoidable — you need the key before you can lock it
     — but it means the key can name an entry that is gone by lock time. New behaviour:
     `entry` re-reads as `None`, `requested is None`, clean `not_found` at 435. Old
     behaviour: `entry` was read in the same `_runs_lock` critical section as
     `candidates`, so the destroy proceeded with a work dir a concurrent destroy had
     already `rmtree`d and returned a `tofu … failed` error. *An improvement, and the
     task did not say it was changing this.*
   - **A cold destroy can become a cached destroy.** If an apply lands between key
     resolution and lock acquisition, the re-read at `main.py:416` finds the new entry,
     so the destroy takes the `if entry:` branch (418) and uses `entry["dir"]` and
     `entry["params"]`, silently discarding `body.params`. Old code decided
     cached-vs-cold from the snapshot, so an entry that appeared *after* the request was
     sent did not suppress the caller's params. The window in which the caller's params
     are ignored has therefore grown. *Probably the right call — destroying with the
     applied vars matches the state that exists — but it is a semantic change to a
     documented API behaviour (the `DestroyRequest.params` docstring at 100-106) and
     the task did not mention it.*
   - **`logger.warning` for the fallback moved out of `_runs_lock`** (was at old
     lines 399-402 inside the `with`; now 400-403 outside). Incidental improvement:
     logging (blocking I/O) no longer happens while holding a `threading.Lock` in the
     event loop. *Unmentioned, harmless.*

   Everything else in the function is unchanged — see Notes for how I established that.

4. **The committed evidence does not itself show the reviewed code was what ran.**
   Both logs' raw output is byte-identical to the capture they replace: the diff of
   `docs/evidence/S24.log` and `S27.log` is `+3 -3`, the three header lines only. That
   is expected here (the checks are unchanged and the runner behaves identically under
   sequential load), but it means the artefact carries no signal about the lock — the
   same shape of complaint as `runner-workdir-leak-findings.md` concern 1. What does
   prove it, and is recorded nowhere in the evidence: the runner image was built at
   `2026-09-29T14:11:44Z`, 18s after `jit-runner/main.py`'s mtime and 18s before the
   S24 capture at `14:12:02Z`; and `docker exec jit-runner cat /opt/jit-runner/main.py`
   is byte-identical to the working tree, with `async with _run_lock(key)` at line 414
   (delete) and 297 (create). I verified all of that myself; a future reader cannot.

## Notes

- **Question 8 — the serialisation is correct.** Both sides lock the same key.
  `create_run`: `key = (req.workspace, req.module)` (292) → `async with _run_lock(key)`
  (297). `delete_run`: `key = (workspace, requested)` (392) or, for the no-module
  fallback, `key = candidates[0]` (403) where `candidates` is drawn from `_runs`' keys,
  i.e. itself `(workspace, module)` — then `async with _run_lock(key)` (414). The
  resolve-and-destroy is entirely inside the block (414-533), and the entry is re-read
  under it: `async with _run_lock(key): with _runs_lock: entry = _runs.get(key)`
  (414-416). Both named races close: the apply cannot reach
  `_apply_run`'s `rmtree(stale_dir)` (361-373) while a destroy holds the lock, and the
  destroy's `_runs.pop(key, None)` (523) cannot pop an entry the apply just wrote (369)
  because the two critical sections are now mutually exclusive.
- **Question 9 — nothing is held that should not be.** `_runs_lock` is a
  `threading.Lock` and is never held across an `await`: the four sites (394, 415, 523,
  531) are all synchronous get/list/pop with no coroutine inside. `_run_locks_guard`
  is released inside `_run_lock()` before the returned lock is awaited, so it is never
  held while acquiring `_run_lock`. Lock ordering is `_run_lock` → `_runs_lock` on both
  paths (`create_run:297→298`, `_apply_run` called at 305 with the run lock held then
  taking `_runs_lock` at 362, `delete_run:414→415`); the pre-lock `_runs_lock` at 394
  is acquired and released with nothing else held, so there is no inversion. `async with`
  releases `_run_lock(key)` on every return path and on exception — every return from
  line 414 onward is lexically inside the block, and the two pre-lock returns (397,
  405) do not hold it. Holding the asyncio lock across a 600s `tofu` call is intended
  and does not block the event loop, because `_run_tofu_async` is
  `await asyncio.to_thread(_run_tofu, …)` (180-182), not a blocking `subprocess.run`
  in the coroutine.
- **Question 3 — the 128+/116- diff hides a ~10-line change.** The whole body was
  re-indented one level, so `git blame` now attributes every line of the destroy path to
  `f8bf679`. I checked it mechanically rather than by eye: extracting `delete_run` from
  both revisions and stripping all leading whitespace, the content diff is confined to
  the key-resolution restructure, the new comment, the `async with`, the
  `elif body and body.module` → `elif requested` swap and three comment rewraps.
  **Everything from `if entry:` to the final `except Exception as e:` is byte-identical
  to `a374e21`** — no `if not cached: rmtree` guard, no `state.returncode == 0 else []`,
  no pop-on-success, no pop-in-`except` was dropped in the re-indent. (The copy loop
  being inside the `try` — `runner-workdir-leak-findings.md` concern 3 — was already
  true at `a374e21` and is unchanged here.)
- **Question 11 — failure modes nobody covers, and what I would attack first.**
  (i) *First:* a DELETE issued before a POST but acquiring the lock after it destroys
  the *post* run. It uses `entry["params"]` (the new ones), so nothing is orphaned and
  for postgres the new volume goes with the new container (`S27.sh:87-88`) — but an
  earlier intent silently wins over a later apply, and neither the checkpoints nor any
  test would notice. (ii) `_run_locks` growth via DELETE of arbitrary module names
  — Concern 2. (iii) Runner restart while a request holds the lock: `_run_locks` and
  `_runs` are both in-memory (53-58), the `tofu` thread dies with the container, remote
  state may be half-destroyed, and the retry takes the cold path — pre-existing debt
  already recorded as "Runner restart orphans dirs" in `HANDOFF.md` P0.2; the lock does
  not make it worse and cannot make it better. (iv) A destroy now holds its key's lock
  across up to four 600s `tofu` calls (`init`, `state list`, `state rm`, `destroy`), so
  a kopf delete or create for that key queues behind it and can outlast kopf's handler
  timeout — true of `create_run` since the lock was introduced, now symmetric.
  (v) Two destroys of *different* modules in one workspace still run concurrently
  (different keys); their container names and state keys differ, so I do not see a
  collision, but nothing asserts it.
- **ADR 0023 is now stale on one point.** `docs/decisions/0023-stage-h-concerns-accepted.md:44`
  still reads "`delete_run` is unlocked". Correcting it was outside this step's allowed
  file list, and `HANDOFF.md` P0 item 2 already carries the "annotate the bullet so a
  reader doesn't think it's closed" debt — noting only that the annotation is now two
  defects behind, not one.
- **`docs/HANDOFF.md` has never been committed.** `git log -- docs/HANDOFF.md` is empty
  and `git status` shows it as `??`, untracked and not gitignored — so the document this
  prompt directs the reviewer to read is absent from the repository, and it (plus this
  untracked prompt) permanently inflates every future evidence log's `pending N` header.
  Reading the implementer's provenance: `pending 2` at the S24 capture and `pending 3`
  at the S27 capture reconcile exactly as `HANDOFF.md` + `jit-runner/main.py` (+ the
  previous log, excluded for its own run), so the dirty-tree accounting for this range
  is clean. Pre-existing and outside this step's file list — no action implied here.

## Checkpoint assessment

Both checkpoints pass on my clean runs, with the committed evidence untouched:
`scripts/checkpoint.sh 24 /tmp/S24-review.log` → exit 0, `PASS S24: cache keyed on
params; changed params re-apply; state rm conditional on postgresql_* in state; volume
goes with its container`; `scripts/checkpoint.sh 27 /tmp/S27-review.log` → exit 0,
`PASS S27: postgres in place, volume-surviving replaces, service_url_<db>, clean
destroy`. `git status --porcelain` shows no tracked file modified after my runs.
Neither checkpoint asserts this step's goal: S24 and S27 are sequential HTTP scripts
whose greps cover the params-keyed cache, the changed-params re-apply, the work-dir
count under `/tmp`, the conditional `tofu state rm`, and volume/container removal —
nothing observes ordering, concurrency, or the per-run lock, and both would print the
same PASS with `async with _run_lock(key)` removed. That is acceptable for this step
because the step claimed no checkpoint amendment: `HANDOFF.md` P0.1 asks only to run
them, and ADR 0024's Consequences explicitly carves this race out of the S24 amendment
and says it "needs its own reviewed step". Per the prompt's rules I record that as
Concern 1 rather than a Blocker; it does mean the fix is gated by this review alone.

Verdict: CONCERNS
