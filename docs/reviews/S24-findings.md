# S24 Review

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: BLOCKED

Prompt intact: twelve numbered questions, counted (1-5 mechanical, 6-7 run, 8-12
substance). Range `f39fb33..614bd46` = 4 commits, 6 files, +208/-24:
`docs/build-plan.md`, `docs/decisions/0008-…`, `docs/evidence/S24.log`,
`jit-modules/modules/postgres/variables.tf`, `jit-runner/main.py`,
`scripts/checks/S24.sh`. HEAD is `6ee480c`, which adds only
`docs/reviews/S24-review-prompt.md`; the working tree is clean, so the tree I ran
against is the reviewed code. I ran `scripts/checkpoint.sh 24 /tmp/S24-review.log`
privately — committed evidence untouched.

## Blockers

1. **Rule 4 — a file outside the step's declared scope was edited:
   `jit-modules/modules/postgres/variables.tf`** (added in `614bd46`). It gains a
   `databases` variable (`list(string)`, default `[]`). The step's allowed list is
   `docs/designs/runner-api.md`, `jit-runner/`, `docs/designs/declarers-and-consumers.md`,
   `docs/lessons.md`, `docs/evidence/S24.log`,
   `docs/decisions/0008-s24-checkpoint-setup-fixes.md`, `scripts/checks/S24.sh`,
   `docs/build-plan.md` — `jit-modules/` is not on it, and the prompt's only rule-4
   exemption is for the two review-machinery files (neither of which is in this range
   anyway). *Why it blocks:* a Terraform module is implementation, and the build plan
   gives `jit-modules/modules/postgres/` to S27 ("S27 wires it to postgresql_database
   resources"; ADR 0008's Consequences already warns that S27 "must not re-declare it"),
   so S24 has quietly consumed S27's file. Mechanical finding → BLOCKED by the verdict
   rules, no judgement required.
   *Mitigating facts, recorded so the remedy is the right one:* ADR 0008's Decision text
   names the file and the change is load-bearing — OpenTofu 1.8.1 in both the host and
   the runner image refuses an undeclared `-var` (`Error: Value for undeclared variable`,
   verified), so the frozen checkpoint's postgres create, which posts
   `"databases":["voting"]`, cannot succeed without it. **Remedy is a scope decision,
   not a revert** — reverting turns `scripts/checks/S24.sh` red. Either the human/orchestrator
   adds `jit-modules/` to S24's scope (a one-line directive or an ADR citing it), or the
   declaration moves to S27 and S24's checkpoint is re-run after S27 lands.

## Concerns

1. **The checkpoint never asserts the cache-hit side of the goal.** Test 1 captures
   `created1`, re-POSTs identical params, then asserts only `status == "success"` and
   `n_cont == 1`; it never compares `Created` across the identical re-POST. An idempotent
   re-apply satisfies both, so a runner with the success cache deleted *entirely* still
   passes `S24.sh`. What is asserted is this step's *keying* (test 2 fails on the old
   workspace-only key) and the `state rm` conditional (tests 3/4). Closing it means
   touching frozen `scripts/checks/S24.sh`, so it needs an ADR: add
   `created_after_identical == created1` to test 1.
2. **A failed `tofu state list` silently removes the safety step.** `jit-runner/main.py:411-415`
   sets `pg_resources = []` whenever `state list` returns non-zero, logs nothing, and
   proceeds to `tofu destroy` — which then fails with exactly the refresh error S24 exists
   to prevent, reported only as `tofu destroy failed`. Attack vector #1: induce a state-list
   failure (backend hiccup, stale lock) against a postgres destroy and the step's whole
   purpose evaporates with no trace. The `state list` stderr should be surfaced or the
   destroy refused.
3. **The name filter is prefix-only at the root.** `main.py:414` matches
   `startswith("postgresql_")`, so `data.postgresql_*` and `module.<x>.postgresql_*`
   entries are invisible. S27 plans root-level resources, so behaviour matches the design
   today; a later module wrap restores the breakage silently. Attack vector #2.
4. **New temp-dir leak on every params change.** `_apply_run` stores
   `_runs[key] = {"dir": work_dir, …}` (`main.py:308-310`) over the previous entry without
   `rmtree`, and destroy only removes the current dir. Pre-S24 a changed-params POST was a
   cache hit, so a second `mkdtemp` never existed; now each update leaks one tree in the
   runner container, unbounded over the PoC's life.
5. **`docs/designs/runner-api.md` — in this step's scope and Read list — is untouched.**
   It never documents the success cache at all, and after S24 the cache-hit/re-apply rule
   is the behaviour S26's controller will depend on; its POST response enum still says
   `applied` while the implementation (before *and* after this step) returns `success`.
   The enum drift is pre-existing, the omission is this step's to close.
6. **Two `docs/build-plan.md` hunks belong to ADR 0007, not to S24**: the ADR 0007
   reference added to S26's Read line, and two rows added to the S28 invalidations table
   (`declarers-and-consumers.md:100` and `:161`). Allowed file, correct content, but not
   what S24's Do list asks for — and the rows cite design-note line numbers that S28's own
   edits will move.
7. **ADR 0008 makes the checkpoint environment-dependent.** The injection hardcodes MinIO
   at `172.19.0.11:9000` with its credentials inside the runner container
   (`scripts/checks/S24.sh:71`), and the redis create hardcodes `ip 172.19.0.192`. Both
   hold here today (verified: MinIO is `172.19.0.11`, `.192` free), but a recreated MinIO
   or a tenant handed `.192` fails the checkpoint for reasons unrelated to the runner —
   a false FAIL handed to the next reviewer.
8. **`delete_run` still takes no `_run_lock`**, so a POST and a DELETE on the same key can
   interleave `state list` / `state rm` / `tofu destroy` against one state file. Destroy
   was already outside the lock before S24; the new `state rm` adds a second unlocked state
   mutation, and `tofu state rm` takes the state lock by default, so the loser sees an
   opaque lock error rather than a clean refusal.

## Notes

- **Q1:** `scripts/checks/S24.sh` is touched — sanctioned by ADR 0008, which exists in the
  range and was amended in the same three commits as the script
  (`e6e8aeb`, `ebe311e`, `da000d9`). Nothing under `.clinerules/`, CI or scanner config.
  **Judging ADR 0008 as a decision:** its five setup claims spot-check out — redis `ip` is
  declared with no default (`jit-modules/modules/redis/variables.tf:6`), the runner publishes
  `-p 8100:8080` (`deploy/runner.sh:66`) and `S06.sh:9` drives that published port, destroy
  returns `{"status":"destroyed"}` (`main.py:437`), and curl `-d` without a Content-Type is
  form-encoded. No assertion was deleted or softened; the amendment *adds* one
  (`grep -qi 'state rm'` on the positive side) and widens the destroy check to
  `success|destroyed`, which only a successful destroy can satisfy (a failure returns
  `status: error`). Accepted as a decision; the file it edited is a different question — see
  Blocker 1, which is about `jit-modules/`, not `scripts/checks/`.
- **Q2:** no dependency added — `hashlib`/`json` are stdlib; `python3` and `tofu` are already
  in the runner image (`OpenTofu v1.8.1`, `Python 3.11.2`, both verified in-container).
- **Q3:** nothing deleted or weakened; the pre- and post-amendment scripts differ only in
  URL, Content-Type headers, the redis `ip`, the destroy status string, and additions.
- **Q5:** `docs/todo.md` untouched; S24's boxes are still
  `- [ ] check  - [ ] review` (`docs/todo.md:124`).
- The prompt's rule-4 note says the range contains `docs/reviews/S24-findings.md` and
  `docs/reviews/S24-review-prompt.md`; neither is in `f39fb33..614bd46` (the prompt landed
  at `6ee480c`). Harmless — there is simply nothing in-range to exempt.
- `docs/designs/declarers-and-consumers.md:43` ("`POST /v1/runs` returns its cached success
  … regardless of the params sent") is now stale prose inside the Problem section. The design
  is read-only outside S28's named amendments and S28's new rows do not name line 43, so no
  step owns the edit.
- The evidence capture records `commit da000d9` with 3 pending changes (those changes are
  `614bd46`). I confirmed the running container's `/opt/jit-runner/main.py` is md5-identical
  to the committed tree (`7719492d…`), so my run exercised the reviewed code rather than a
  stale image.
- Sequencing: making updates real before S26's conflict guard exists means two disagreeing
  declarers would flip-flop the container. The design says "ship this first" (line 160), so
  it is sanctioned, and the S14-era controller does not POST params on resync — the window is
  theoretical today.
- The runner's `params_hash` and the controller's `attemptedParamsHash` (design `:140`, S26)
  are independent hashes; the design specifies no algorithm, so no contract is broken — but
  no doc states they are independent either.
- Q10, beyond the blocker: `RunRequest.params` widening to `Dict[str, Any]` and the JSON
  encoding in `_var_args` are outside S24's Do list but are the adaptation ADR 0008 records
  and the design's param surface requires (`databases` is a list, `settings` an object);
  strings pass through unchanged, and I verified OpenTofu 1.8.1 accepts a JSON object literal
  (`-var 'settings={"a": "b"}'` resolves `var.settings.a`).
- Q12: yes — `_params_hash`, `_var_args` and the destroy block each carry a why-comment that
  names the failure they prevent, the `databases` variable documents its own S24/S27 split,
  and ADR 0008 holds the checkpoint's rationale; only Blocker 1's *ownership* is not
  recoverable from the code (it lives in the ADR).

## Checkpoint assessment

`scripts/checkpoint.sh 24 /tmp/S24-review.log` passes on my clean run at HEAD — commit
`6ee480c`, zero pending changes, `PASS S24: cache keyed on params; changed params re-apply;
state rm conditional on postgresql_* in state; volume goes with its container`, exit 0 — and
the committed capture records the same line, so this is not leftover state. The checkpoint
does assert the step's goal where it matters: test 2 (changed `maxmemory` → `Created` moves
and the container runs `--maxmemory 128mb`) fails if the params-hash keying is reverted to
the old workspace-only key, and tests 3+4 assert the conditional both ways — no `state rm`
logged for a redis-only destroy, `state rm` logged *and* a destroy that succeeds for a
workspace whose state holds an injected `postgresql_database` after the container was
pre-removed. I judged ADR 0008's injection to make the conditional real: the injected entry
references the postgresql provider, the container is gone, so without `state rm` the refresh
fails and the destroy returns `error`, which the `success|destroyed` grep rejects; the added
positive log assertion pins the mechanism rather than the outcome. The one gap is the
cache-hit half (Concern 1): test 1 never compares `Created` before/after the identical
re-POST, so deleting the success cache altogether would still pass every assertion — the
change-detection half is asserted, the "identical params are the cache" half is not.

Verdict: BLOCKED
