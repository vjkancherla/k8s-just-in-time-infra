# Review prompt — runner ops/docs hardening (ADR 0023 debt 1: restart orphans, runner-api.md, plus R1 concerns 2-3)

You are reviewing work you did not do and have no stake in.

A different model closed the remaining runner items from ADR 0023 debt 1 and tightened two
concerns from the previous runner review. Your job is to find what is wrong with it. Do not
be agreeable. Do not fix anything.

**You may not modify any file except your findings file.** No commits, no edits, no "while I
was here". Report only.

**First, check this prompt is intact.** It should contain twelve numbered questions. If it
has fewer, or reads like a summary, stop and write a findings file with verdict BLOCKED and
the single blocker "review prompt was abbreviated".

## What the step was supposed to do

1. **Runner restart orphans dirs** (`docs/HANDOFF.md` P0.2): `_runs` is in-memory and a plain
   `docker start` of a stopped runner keeps the container's `/tmp` but loses `_runs`, so every
   `jit-*` dir is unreachable. Sweep them at startup.
2. **`runner-api.md` stale** (P0.2): it documents neither the params-keyed success cache
   (S26 depends on it) nor the true destroy-params type (`Dict[str, Any]`, not `Dict[str,
   str]`), and it still showed the POST status as `applied` when the code returns `success`.
3. **ADR 0023 debt 1 wording** (P0.2): annotate the bullet so a reader does not think it is
   closed (it bundled five defects).
4. **Resolve R1 review concerns 2 and 3** (`docs/reviews/runner-r1-robustness-findings.md`):
   (2) the "No state file was found" test was a case-sensitive substring over an ANSI-encoded
   vendor string; (3) the `postgresql_` regex matched the type segment in the *name* position
   too (`docker_container.postgresql_mirror`, `data.postgresql_*`), which the old prefix
   filter excluded.

Nothing else was in scope. `make jit-up` rebuilt the runner; `scripts/checkpoint.sh 24` and
`27` pass and their logs are committed.

## What the step was allowed to touch

```
jit-runner/main.py
docs/designs/runner-api.md
docs/decisions/0023-stage-h-concerns-accepted.md
docs/evidence/S24.log
docs/evidence/S27.log
```

## What to read

- `docs/HANDOFF.md` P0.2 - the items, in full
- `docs/decisions/0023-stage-h-concerns-accepted.md` - debt 1 and the new status note
- `docs/reviews/runner-r1-robustness-findings.md` - concerns 2 and 3 being resolved
- `docs/designs/runner-api.md` - the doc
- `jit-runner/main.py` - `_sweep_orphan_work_dirs`, `lifespan`, `_PG_RESOURCE_RE`, the
  state-list branch
- `git diff a1523be..d917804` - what was actually done
- `scripts/checks/S24.sh`, `scripts/checks/S27.sh` - the assertions that passed

## First, mechanically

1. Did the diff touch anything under `scripts/checks/`, `.clinerules/`, CI config, or any
   scanner config? **Blocker**, no judgement required.
2. Did it add a dependency the step did not name? Blocker. (Stdlib is not a dependency.)
3. Did it delete or weaken an existing test or assertion? Blocker.
4. Did it create or edit files outside the list above? Blocker.
5. Did it tick a box in `docs/todo.md`? Blocker.

## Then, run it

6. **Run `scripts/checkpoint.sh 24 /tmp/S24-review.log` and
   `scripts/checkpoint.sh 27 /tmp/S27-review.log` yourself.** Do they pass *now*? Note: the
   implementer saw one transient S27 failure ("database 'analytics' was not created in
   place") on the first post-rebuild run; the database and its state were present a minute
   later and two subsequent runs passed. If it fails for you, investigate whether it is the
   same transient or a real regression, and say which.
7. **Read the checkpoints.** Do they assert any of this step's four items? If they would pass
   with the fix removed, say so.

## Then, on substance

8. **Startup sweep.** Does `_sweep_orphan_work_dirs` remove exactly the right things at the
   right time? Could it delete a directory a live request is using (e.g. under uvicorn
   reload, multiple workers, or a second process)? Does the `lifespan` wiring actually run
   before requests are served? Is the glob `jit-*` safe?
9. **Regex.** Does `^(?:module\.[^.]+\.)*postgresql_[^.]+?\.` match every address the module
   and `state rm` need (flat, for_each with `["..."]`, module-scoped, nested modules) and
   reject `data.postgresql_*`, `docker_container.postgresql_mirror.x`, and any type whose
   *name* contains `postgresql_`? Test it directly, including edge cases.
10. **Phrase match.** Is `_strip_ansi(state.stdout + "\n" + state.stderr).lower()` the right
    text to test for "no state file was found"? Does it still fail open for a real error that
    embeds the phrase? Is failing open or failing closed the safer direction here, and does
    the code pick the safer one?
11. **Docs and ADR.** Does `runner-api.md` now match the code (status strings, params types,
    cache semantics, resolution order, restart behaviour, error handling)? Is the ADR 0023
    status note accurate about which sub-defects are closed and by which commit, and does it
    avoid rewriting the historical record?
12. **Would you be able to maintain this?** One line.

## Output

Write `docs/reviews/runner-r2-ops-review-findings.md`:

    # runner ops/docs review (a1523be..d917804)

    Reviewer model: <name>
    Verdict: CLEAR | CONCERNS | BLOCKED

    ## Blockers
    <numbered. each: what, where, why it blocks. empty section if none.>

    ## Concerns
    <things you would raise in review but would not stop a merge for.>

    ## Notes
    <observations, no action implied.>

    ## Checkpoint assessment
    <did S24 and S27 pass on your clean runs? do they assert any of this step's items? one
    paragraph.>

Verdict rules:
- Any mechanical finding (1-5) → BLOCKED
- A checkpoint fails when you run it → BLOCKED
- A checkpoint would pass with the logic removed **and the step claimed it asserted the
  fix** → BLOCKED; the step made no such claim, so say it as a Concern instead
- A design disagreement that changes behaviour → BLOCKED
- Everything else → CONCERNS or CLEAR

If you find nothing, say CLEAR and say what you checked. "Looks good" is not a review.

Do not start the next step. Do not offer to.
