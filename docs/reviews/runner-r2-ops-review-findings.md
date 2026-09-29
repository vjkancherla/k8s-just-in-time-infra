# runner ops/docs review (a1523be..d917804)

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: CONCERNS

Prompt integrity: `docs/reviews/runner-r2-ops-review-prompt.md` carries all twelve numbered
questions (Q1-Q5 mechanical, Q6-Q7 checkpoints, Q8-Q12 substance) and reads as a prompt, not
a summary. Range is one commit — `d917804`, parent `a1523be` — touching exactly
`docs/decisions/0023-stage-h-concerns-accepted.md` (+9), `docs/designs/runner-api.md`
(+24/-6), `docs/evidence/S24.log` (+3/-3), `docs/evidence/S27.log` (+3/-3),
`jit-runner/main.py` (+49/-9); `git diff --name-only a1523be..d917804` returns those five
and nothing else. The container's `/opt/jit-runner/main.py` md5 `a820b561675e63b8cc400cf48021474c`
is byte-identical to the committed file, so both of my checkpoint runs exercised the
reviewed code, not a stale image.

## Blockers

None.

1. No mechanical finding (Q1-Q5): nothing under `scripts/checks/`, `.clinerules/`, CI or
   scanner config is touched (no file under `scripts/checks/` or `scripts/checkpoint.sh` is
   in the range, so there is no ADR under review); the only added import is
   `from contextlib import asynccontextmanager` (stdlib, not a dependency —
   `jit-runner/requirements.txt` unchanged); no test or assertion is deleted or weakened —
   both evidence logs changed header lines only, so their raw output is byte-identical to
   the captures they replaced (`git diff a1523be..d917804 -- docs/evidence/S*.log` = 6
   removed + 6 added = the `started`/`commit`/`pending` lines, +3/-3 each); no file outside
   the allowed five appears; `docs/todo.md` is untouched (no box ticked).
2. Both checkpoints pass on my clean runs (Q6) — see Checkpoint assessment.
3. No design disagreement: `docs/HANDOFF.md` P0.2 names the three items verbatim
   ("`runner-api.md` stale", "Runner restart orphans dirs", "ADR 0023 debt 1 wording") and
   the diff implements exactly those plus R1 concerns 2-3, nothing else. The ADR 0024 claim
   in the new status note checks out (`0024-s24-workdir-leak-assertion.md` amends S24 with
   the `/tmp/jit-s24-check-*` count that `S24.sh:50-52` now carries).
4. Nothing here is a frozen-checkpoint amendment, and every defect I found is a
   not-yet-closed half of a named item rather than a regression, so per the verdict rules
   the review lands on CONCERNS.

## Concerns

1. **R1 concern 2 is only half closed: the phrase test still fails open, and the change
   made the fail-open side strictly wider.** `jit-runner/main.py:577-578` now reads
   `err_text = _strip_ansi(state.stdout + "\n" + state.stderr).lower()` and tests
   `"no state file was found" not in err_text`. That fixes the half the prompt names
   (case-sensitive substring over an ANSI string): I verified
   `"\x1b[31mNo state file was found!\x1b[0m"` and the re-cased `"no state file was
   found!"` both now proceed as empty, where the old `phrase not in state.stderr` refused
   the re-cased one — and the pinned-version claim in the comment holds (Dockerfile:7 pins
   OpenTofu 1.8.1). What it does not fix is the other half of R1 concern 2, which R1
   *demonstrated*: `"Error: AccessDenied: ... (No state file was found?)"` and
   `"Error: failed to read state: No state file was found"` still classify as an empty
   workspace (I ran the exact expression — both return "PROCEED as empty"). The change also
   adds `state.stdout` to the haystack, which can only add fail-open cases (a real
   `"connection refused"` on stderr proceeds as empty if stdout carries the phrase), and it
   subtracts no fail-open case: the new test is a superset of the old one, so nothing that
   previously refused now refuses. So the net effect is "fewer false refusals, unchanged
   false proceeds, one new false-proceed path". Failing closed is the safer direction here
   and the code does not pick it. The concrete path: `docker rm -f` of the container runs at
   `main.py:527-533`, *before* the `state list` at `:564`, so a wrongly-classified "empty"
   proceeds to `tofu destroy`, which — per R1's real-OpenTofu measurement — returns rc 0
   (`No changes... Destroy complete!`) on a missing state; the runner then returns
   `destroyed` and pops the entry (`:616-617`) while the `*-postgres-data` volume and the
   state object it could not read are still there: the "volume outlived its container" trap
   S27 asserts against, reached without any assertion noticing. An anchored test closes it
   without giving up the cold-destroy path, e.g. the whole stripped stderr equal to (or
   ending at) the pinned message rather than "the phrase appears anywhere in stdout+stderr".
2. **Neither checkpoint asserts any of this step's four items, and the committed evidence
   proves it: the raw output of both logs is unchanged by the range.** S24 asserts the
   params-keyed cache, the changed-params re-apply, `/tmp/jit-s24-check-*` counts (1 then
   0), no `state rm` for redis-only state, and `state rm` for the injected address
   `postgresql_database.voting` (`S24.sh:105,116`); S27 asserts in-place database adds,
   volume survival and a clean destroy. Against this range: neither script restarts the
   runner, so the startup sweep never runs; every `state list` they drive returns rc 0, so
   the phrase branch (`main.py:565-585`) is never entered; the injected address is
   root-level and matched identically by the old `(?:^|\.)postgresql_...` filter and the new
   anchored regex, so the concern-3 change is not discriminated (I confirmed by running the
   new regex over the full address matrix — flat, `["..."]` for_each, `module.pg.`, nested
   and `module.a["x"].module.b["y"].` all match; `data.postgresql_*`,
   `docker_container.postgresql_mirror.x`, `module.postgresql_foo.bar` all reject — but S24
   only feeds it one root-level address); docs and ADR wording are never asserted. Deleting
   the whole patch still prints both PASS lines — which is exactly what the header-only diff
   of the two committed logs shows. The step claims only that the checkpoints "pass and
   their logs are committed", not that they gate these fixes, so per the verdict rules this
   is a Concern, not a blocker; the discriminating evidence for items 1 and 4(b) is the
   probes (implementer's, mine) that live only in `docker logs`.
3. **`_sweep_orphan_work_dirs` logs success unconditionally.** `main.py:117-119` calls
   `_rmtree(str(p))` and then `logger.info(f"Swept orphan work dir {p}")`, but `_rmtree`
   (`:81-97`) swallows `OSError` into a warning and returns normally — so a sweep that
   failed removes nothing and still records "Swept orphan work dir" above the warning. This
   sits in the very item whose theme is "a failed removal is silent"; a one-line reordering
   (log the sweep only when the path is gone, or have `_rmtree` return a bool) restores the
   honesty the rest of the patch is arguing for.
4. **The sweep's safety rests on a single-worker deployment that nothing states or
   enforces.** `_sweep_orphan_work_dirs` deletes every `jit-*` dir it finds, and it runs in
   each worker's `lifespan` (`main.py:122-131`). It is correct today because
   `jit-runner/Dockerfile:20` runs one `uvicorn main:app` with no `--workers` and no
   `--reload`, so startup completes before the first request is accepted and `_runs` is
   empty; `--reload` would also be safe (the whole process dies). With `--workers N`, a
   later-starting worker's lifespan would delete work dirs a peer is actively using — a live
   `tofu apply` in `/tmp` deleted mid-run. Nothing in the docstring or `runner-api.md:168-172`
   says "single worker is load-bearing". Worth one sentence, since it is the only condition
   under which this fix is safe.
5. **The ADR 0023 status note's closure list is accurate but its containment claim is not.**
   `docs/decisions/0023-stage-h-concerns-accepted.md:48-55` opens "All five sub-defects in
   this bullet are closed" and then names eight things: the leak, the unlocked `delete_run`,
   the silent `state list` skip, the prefix-only filter, the silent cleanup, the
   cancelled-handler leak, the stale `runner-api.md`, the restart orphan sweep. The bullet
   itself (`:41-45`) contains five — leak, state-list skip, prefix filter, unlocked
   `delete_run`, `runner-api.md` — so "silent cleanup", "cancelled-handler leak" and
   "restart orphans" are not in it (the first two are HANDOFF P0.2's bullets, the third is
   HANDOFF P0.2's too, never ADR 0023's). Every closure and hash cited is correct
   (`7a15db8` "remove the work-dir leaked...", `f8bf679` "take the per-run lock in
   delete_run", `6105ce2` "refuse to destroy on an unreadable state, log cleanup failures,
   handle cancellation", this commit for the last two), and the note is an appended blockquote
   with the historical bullet untouched, so nothing is rewritten — but a reader who counts
   to five and then counts eight items will not know which claim to trust. Suggest "all five
   sub-defects in this bullet (plus the three related items HANDOFF P0.2 lists alongside)".

## Notes

- **Q8, sweep correctness (verified live, my probe).** I created `/tmp/jit-review-sweep-probe`
  and `/tmp/review-keep-probe` in the container and ran `docker restart jit-runner`
  (15:35:34Z): the `jit-*` probe was removed, the non-`jit-*` probe survived, `GET /health`
  returned 200, and the log order is `Waiting for application startup` → `Swept orphan work
  dir ...` → `Application startup complete` → `Uvicorn running` → first `GET /health 200` —
  so the sweep runs during lifespan startup and before any request is served. I removed my
  keep-probe afterwards; the swept probe is gone. `_runs` was empty before the restart (no
  `jit-*` dir existed), so nothing live was lost. The implementer left the same proof in
  `docker logs` at 15:11:49 (`Swept orphan work dir /tmp/jit-orphan-probe`), but that probe
  is not committed anywhere. The glob is safe in this container: the only `jit-*` writers are
  `main.py:368` and `:513`; S24's `mktemp -d` dirs and `s24-st*.json` are not matched (they
  survived my restart), and `shutil.rmtree` refuses a top-level symlink rather than following
  it.
- **Q9, regex.** `^(?:module\.[^.]+\.)*postgresql_[^.]+?\.` is the exact pattern R1
  suggested; I ran it against 21 addresses and it accepts every address the module and
  `state rm` need (flat, `this["voting"]`, `module.pg.`, `module.a.module.b.`,
  `module.pg["a"].`, `module.a["x"].module.b["y"].`) and rejects `data.postgresql_*`,
  `docker_container.postgresql_mirror.x`, `aws_s3_bucket.postgresql_backups.x`,
  `module.postgresql_foo.bar`, `xpostgresql_database.a`. One latent hole: a module *instance*
  key containing a dot — `module.pg["a.b"].postgresql_database.x` — fails, because `[^.]+`
  stops at the dot inside the brackets; the module blocks needed to produce it do not exist
  anywhere in `jit-modules/` (each module directory is deployed as the root module), and the
  pattern is the reviewer's own suggestion, so this is a Note, not a finding. `state rm`
  receives `line.strip()` of the same string the regex matched (`main.py:590-592`), so
  addresses are not re-formatted.
- **Q10, direction.** Case/ANSI handling: correct. Haystack choice: adding `state.stdout`
  buys nothing (the phrase has never been observed on stdout) and can only widen the
  fail-open set. Substring-anywhere matching: unchanged from before, i.e. still the less
  safe of the two directions — see Concern 1.
- **Q11, doc/code match.** Checked line by line: POST status `success` (was `applied`) ✓,
  no `applied` left anywhere in the file ✓; POST `params` "string verbatim, list/object/
  number JSON-encoded" matches `_var_args` (`main.py:197-210`) ✓; destroy `Dict[str, Any]`
  matches `DestroyRequest.params` (`:164`) ✓; the cache paragraph matches
  `_params_hash` + the `status == "success" and params_hash == ...` hit test
  (`:184-194, 356-363`) and the stale-dir removal (`:419-431`) ✓; the module resolution
  order matches `:458-474` ✓; the destroy status table (`destroyed`/`not_found`/`error`
  including `state list`/`state rm`) matches ✓; the lock paragraph matches `:482` ✓; the
  restart paragraph (`:168-172`) matches the sweep ✓; env-var defaults match `:43-51` ✓;
  `/health` is unauthenticated ✓. One pre-existing line the range left in place is now
  stale: `runner-api.md:181` "Failed destroys leave the workspace in a retryable state (the
  in-memory entry is kept)" is false for the generic handler, which pops the entry
  (`main.py:631-632`) — every *tofu* failure path does keep it, so the bullet is 90% right
  and it was not touched by this range; noting it because Q11 asks whether the doc now
  matches the code on error handling.
- The `_sweep_orphan_work_dirs` docstring's closing clause — "the one case
  `deploy/runner.sh down`/`up` does not cover" — is attached to the wrong noun: `make jit-up`
  *is* `runner.sh build; down; up` (`scripts/jit-up.sh:61-63`), so `down`/`up` is precisely
  what clears the dirs; the sentence means "`docker start` is the case down/up never runs".
  `runner-api.md:168-172` states the same fact clearly.
- Probe residue I am disclosing: my S24 run left the frozen check's own artefacts in the
  container — `/tmp/s24-st.json`, `/tmp/s24-st2.json`, `/tmp/tmp.Jsis41sQw1` (the implementer's
  15:12 run left `/tmp/tmp.vVKIKLFL6V`). They are `S24.sh:78-106`'s `mktemp`/`tofu state
  push` scratch, not runner work dirs, they are not swept, and cleaning them is not mine to
  do. No `s24-*`/`s27-*` containers, volumes or `jit-*` dirs remain.
- The committed evidence headers read `commit a1523be / pending 4` (S24, 15:12:14Z) and
  `pending 5` (S27, 15:22:15Z) — capture-then-commit-in-the-same-commit, so the logs
  themselves cannot prove they tested the committed state; the md5 match between the
  container's `main.py` and `d917804`'s is what closes that gap.
- Out of prompt scope, not run: `make jit-verify`, the J-suite, S06/S07/S14, `make test-up`.
- **Q12 maintainability:** yes — every decision point quotes the debt wording it answers
  (sweep, refuse branch, cancel handlers) and the pinned-version rationale sits next to the
  phrase, so intent is recoverable cold; only the unconditional "Swept" log line and the
  mis-attached docstring clause cost a second read.

## Checkpoint assessment

`scripts/checkpoint.sh 24 /tmp/S24-review.log` and `scripts/checkpoint.sh 27
/tmp/S27-review.log` both PASS on my runs at commit `d917804` with `pending 0` (so they are
not leftover state): S24 `PASS S24: cache keyed on params; changed params re-apply; state rm
conditional on postgresql_* in state; volume goes with its container`, started 15:26:38Z,
exit 0; S27 `2 ok additive databases ... 3 ok settings replace ... 4 ok destroy ... PASS
S27: postgres in place, volume-surviving replaces, service_url_<db>, clean destroy`, started
15:27:09Z, exit 0. The implementer's reported S27 transient ("database 'analytics' was not
created in place") did not recur for me on either run. Neither script asserts any of this
step's four items: no runner restart (sweep never runs), no failing `state list` (phrase
branch never entered), one root-level injected address that both the old and new regex match
(concern-3 change not discriminated), and no doc/ADR assertion — and the proof is that the
committed logs' raw output is byte-identical to their pre-range captures, so deleting the
whole patch still prints both PASS lines. The step made no claim that these checkpoints gate
the fixes ("`scripts/checkpoint.sh 24` and `27` pass and their logs are committed"), so per
the verdict rules this is Concern 2, not a blocker; the discriminating evidence for the range
is my sweep probe and the implementer's, neither of which is committed.

Verdict: CONCERNS
