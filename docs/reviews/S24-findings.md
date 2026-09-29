# S24 Review

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: CONCERNS

Prompt intact: twelve numbered questions, counted (1-5 mechanical, 6-7 run, 8-12
substance). Range `f39fb33..2de7d98` = 9 commits, 10 files:
`docs/build-plan.md`, `docs/decisions/0008-…`, `0009-…`, `0010-…`,
`docs/evidence/S24.log`, `docs/reviews/S24-findings.md`,
`docs/reviews/S24-review-prompt.md` (both exempt), `jit-modules/modules/postgres/variables.tf`,
`jit-runner/main.py`, `scripts/checks/S24.sh`. HEAD is `8a32d56`, which adds only
`docs/reviews/S24-review-prompt.md`; the working tree is clean, so the tree I ran against
is the reviewed code. I ran `scripts/checkpoint.sh 24 /tmp/S24-review.log` privately —
committed evidence untouched — and left no containers, volumes or state behind.

## Blockers

None.

## Concerns

1. **`DestroyRequest.params` was not widened with `RunRequest.params` — the design's
   "Same as POST" contract is now false.** `jit-runner/main.py:82` is
   `params: Dict[str, Any]`; `jit-runner/main.py:100` still reads
   `params: Dict[str, str] = {}`, while `docs/designs/runner-api.md:112` documents the
   destroy body as "`params` | object | no | Same as POST — needed when there's no cached
   run". A cold destroy (no in-memory entry — the registry is lost on restart,
   `runner-api.md:156`) that names a module and carries a list or object param
   (`databases`, `settings`) is rejected with a 422 before the handler runs, so the
   destroy never happens and nothing retries it. That is exactly the design's TTL-sweep
   destroy of a postgres claim. It does not fire today, which is why this is a concern
   and not a blocker: no client in this range sends non-string destroy params — the frozen
   checkpoint's destroy body deliberately omits `databases` (`scripts/checks/S24.sh:102`)
   and the current controller stringifies every param before both calls
   (`jit-controller/main.py:485`, `:705`), so destroy's observable behaviour is
   byte-identical to before this range. It becomes live the first time a controller stops
   stringifying (S26/S27). Fix: widen `DestroyRequest.params` to `Dict[str, Any]`, or
   amend `runner-api.md:112` to say destroy params are strings only.
2. **A failed `tofu state list` silently deletes the safety step.**
   `jit-runner/main.py:411-415` sets `pg_resources = []` whenever `state list` returns
   non-zero, logs nothing, and proceeds to `tofu destroy` — which then fails with exactly
   the refresh error S24 exists to prevent, reported only as `tofu destroy failed`. The
   design (`declarers-and-consumers.md:179`) says the runner runs `state rm` before
   destroy; on an unknown state listing the code assumes "no postgresql_*" rather than
   refusing. Attack vector #1: a stale state lock or a MinIO hiccup during a postgres
   destroy and the step's whole purpose evaporates with no trace. Surface `state list`'s
   stderr, or return the error. (Carried from the previous review; still unfixed.)
3. **The name filter is prefix-only at the root.** `jit-runner/main.py:414` matches
   `line.startswith("postgresql_")`, so `module.<x>.postgresql_database.*` and
   `data.postgresql_*` entries are invisible to `state rm`. S27 plans root-level
   resources, so behaviour matches the design today; a later module wrap re-breaks the
   destroy path silently, and the checkpoint would not notice (it injects a root-level
   entry). Attack vector #2. (Carried; still unfixed.)
4. **Every params change now leaks a 61MB work directory in the runner container.**
   `_apply_run` overwrites `_runs[key]` with a new `work_dir` without `rmtree`-ing the
   previous one (`jit-runner/main.py:307-310`), and destroy only removes the current dir
   (`:433`). Pre-S24 a changed-params POST was a cache hit, so a second `mkdtemp` never
   existed; S24 makes it reachable on every update. Measured on my run: six orphaned
   `/tmp/jit-s24-check-*` directories, 61MB each (~366MB), one per changed-params run —
   and no `jit-s24-pg-*` dir, because that workspace applies exactly once, which pins the
   mechanism precisely. Unbounded over the PoC's life. (Carried, now quantified.)
5. **`docs/designs/runner-api.md` — in this step's scope and Read list — is untouched.**
   It never documents the params-keyed success cache, which is the contract S26's
   controller will depend on ("identical params are a cached no-op, changed params are a
   real run"); its POST status enum still says `applied` (`runner-api.md:69,80`) while the
   implementation returns `success`; and its `DELETE params: Same as POST` is now false
   (Concern 1). No step owns this file: S28's invalidations table covers
   `annotation-to-state.md`, `jit-infra-flows.md`, `jit-infra-poc.md` and
   `declarers-and-consumers.md` only (`docs/build-plan.md:996-1011`).
   (Carried, worsened by Concern 1.)
6. **`delete_run` still takes no `_run_lock`.** A POST and a DELETE on the same key can
   interleave `state list` / `state rm` / `tofu destroy` against one state file
   (`jit-runner/main.py:370-428`). Destroy was already outside the lock before S24; the
   new `state rm` adds a second unlocked state mutation, and `tofu state rm` takes the
   state lock by default, so the loser sees an opaque lock error rather than a clean
   refusal. (Carried; still unfixed.)
7. **The checkpoint is environment-dependent for reasons unrelated to the runner.**
   The injection hardcodes MinIO's endpoint and credentials inside the container
   (`scripts/checks/S24.sh:74-79`) and the redis create hardcodes `ip 172.19.0.192`
   (`:20,:24,:36`). Both held on my run (verified before and after), but a recreated MinIO
   or a tenant handed `.192` fails the checkpoint and hands the next reviewer a false FAIL.
   Accepted as ADR 0008's decision; recorded as a standing risk.

## Notes

- **Q1:** `scripts/checks/S24.sh` is touched — sanctioned by ADR 0008 (committed with each
  of its three edits: `e6e8aeb`, `ebe311e`, `da000d9` each carry the ADR file *and* the
  script) and by ADR 0010 (committed with its edit in `3262fbb`). Nothing under
  `.clinerules/`, CI or scanner config. **Judging ADR 0008 as a decision:** its five setup
  claims spot-check out (redis `ip` has no default — `jit-modules/modules/redis/variables.tf:6`;
  the runner publishes `-p 8100:8080` and answers on `127.0.0.1:8100`, which is how my run
  reached it; the runner returns `{"status":"destroyed"}` — `main.py:437`; curl `-d` without
  a Content-Type is form-encoded and FastAPI 422s it). No assertion was deleted or softened:
  `success|destroyed` can only be produced by a successful destroy (a failure returns
  `status: error`), and the amendment *adds* the positive `grep 'state rm'` assertion.
  **Judging ADR 0009 as a decision:** it is the previous review's recorded remedy — a scope
  decision, not a revert (reverting `databases` turns the frozen checkpoint red), the
  variable carries `default = []` so it changes no behaviour, and S27 inherits it instead of
  re-declaring it. Note the ADR file landed in `5a5e383`, *after* the edit it sanctions
  (`614bd46`); it is a retroactive scope decision, and this prompt sanctions the file for
  rule 4, so I read it as a decision rather than an out-of-scope edit. **Judging ADR 0010
  as a decision:** the assertion it adds is not vacuous — see the checkpoint assessment.
- **Q2:** no dependency added — `hashlib` and `json` are stdlib; no requirements, Dockerfile
  or lock file appears in the range.
- **Q3:** nothing deleted or weakened. The pre- and post-amendment scripts differ only in
  the runner URL, Content-Type headers, the redis `ip`, the destroy status string, and
  additions (the `state rm` log assertion, the `Created` comparison, the injection).
- **Q4:** every file in the range is on the allowed list or exempt (the two
  `docs/reviews/S24-*` review-machinery files). No other file is touched.
- **Q5:** `docs/todo.md` untouched; S24's boxes are still
  `- [ ] check  - [ ] review` (`docs/todo.md:124`).
- **Design conformance (Q8):** no disagreement that changes behaviour. Design
  `declarers-and-consumers.md:160` — "Key the success cache on a hash of module, workspace
  and params" — is implemented exactly by `_params_hash` (`main.py:120-130`, `sort_keys=True`
  so param order cannot flap the hash) plus the cache check at `:248-250`; build-plan S24's
  "a changed params hash is a real run; the old behaviour stays for identical hash" matches
  tests 1/2. The conditional `state rm` matches `declarers-and-consumers.md:179` as the
  build plan states it ("on any run whose state contains `postgresql_*`"), and the S17
  module fallback in `delete_run` is untouched (`main.py:327-368`).
- **Q9 (what the design asks for that the diff does not do):** the two documentation gaps —
  `runner-api.md` (Concern 5) and `declarers-and-consumers.md:43`, whose Problem-section
  bullet "returns its cached success for a workspace regardless of the params sent" is now
  stale prose. S28's two ADR-0007 rows name `:100` and `:161` only, so no step owns `:43`;
  the design is read-only outside those named amendments, so this needs either a new S28 row
  or a human directive.
- **Q10 (scope beyond the Do list):** `RunRequest.params` widening to `Dict[str, Any]` and
  the JSON encoding in `_var_args` — recorded by ADR 0008 and required by the design's param
  surface (`databases` a list, `settings` an object); strings pass through unchanged. The two
  ADR-0007 `docs/build-plan.md` hunks (S26's Read line, two S28 invalidation rows) are the
  human directive's, sanctioned by this prompt. Nothing else.
- **Q11 (failure modes neither doc nor checkpoint covers):** (a) `state list` failure —
  Concern 2; (b) wrapped `postgresql_*` addresses — Concern 3; (c) `state rm` succeeds and
  `tofu destroy` then fails, leaving the logical resources already out of state: a retry
  will not drop them, though the volume still goes with the container on the eventual
  destroy, so exposure is bounded; (d) the cold-destroy 422 — Concern 1; (e) **any cache miss
  replaces the container.** `jit-modules/modules/redis/main.tf:32-35` declares
  `ports { external = 0 }`; OpenTofu writes the assigned host port into state, so every
  apply plans `external = 33233 -> 0 # forces replacement` (I reproduced this on this host
  with OpenTofu 1.8.1 and the same module file: identical vars, `Plan: 1 to add, 1 to
  destroy`, `Created` moved). So a re-POST with *identical* params after the runner restart
  (the in-memory cache is lost — `runner-api.md:156`) destroys and recreates redis and drops
  the queue. Attack vector #3: restart the runner during a vote burst, then let any
  identical POST through. This is pre-existing and is precisely why the design calls the
  cache load-bearing, but neither the design's "idempotent `tofu apply`" framing
  (`declarers-and-consumers.md:42`, quoting the poc) nor the checkpoint covers it. Worth
  recording for S26's backfill rule and S28's docs.
- **Q12:** yes — `_params_hash`, `_var_args` and the destroy block each carry a why-comment
  that names the failure they prevent, the `databases` variable documents its own S24/S27
  split, and the three ADRs hold the rationale the code cannot; only Concerns 1-3 are
  recoverable only by reading this file.
- Sequencing note, not a S24 defect: the current controller stringifies every param
  (`{k: str(v) for …}` — `jit-controller/main.py:485`, `:705`), so a list param reaches the
  runner as Python repr `['voting']`, which `_var_args` passes through as a string and tofu
  rejects with "Invalid expression". The widened surface is unreachable until S26 sends real
  JSON — S26 must not reuse the `str(v)` line.
- I did not run the J/R suites or `make jit-verify` (out of scope for this prompt). Spot
  check: the response contract (`success`), string-param behaviour and the identical-params
  cache hit are all unchanged, so `S06.sh`'s idempotency assertion and the J-suite's
  `params: {}` flows should behave as before.

## Checkpoint assessment

`scripts/checkpoint.sh 24 /tmp/S24-review.log` passes on my clean run at HEAD `8a32d56`
with zero pending changes, printing `PASS S24: cache keyed on params; changed params
re-apply; state rm conditional on postgresql_* in state; volume goes with its container`,
exit 0 — the same line the committed capture records (`docs/evidence/S24.log`, commit
`3262fbb`, pending 0), so this is not leftover state; I also confirmed the running
container's `/opt/jit-runner/main.py` and `/opt/jit-modules/modules/postgres/variables.tf`
are md5-identical to the committed tree, so the run exercised the reviewed code, and I
found no `s24-*` container or volume afterwards. It asserts the step's goal on both halves.
Change-detection: test 2 fails if the params hash is stubbed out of the cache comparison,
because the workspace-only key would return the cached success and `Created` would not move.
Cache-hit: test 1's `created_after_identical == created1` (ADR 0010) fails if the success
cache is deleted altogether — I verified the premise rather than trusting the ADR: an
identical re-apply of the redis module does replace the container (`ports.external = 0` in
config vs the assigned port in state forces replacement, reproduced on this host), so
without the cache the container's `Created` moves and the assertion trips. Both halves are
real. The `state rm` conditional is asserted both ways: negative, a redis-only destroy must
log no `state rm`; positive, a `postgresql_database` entry injected into `s24-pg`'s state
(ADR 0008) with the container pre-removed means the refresh fails without `state rm`, so the
destroy returns `error`, which the `success|destroyed` grep rejects — and the added log
assertion pins the mechanism rather than only the outcome.

Verdict: CONCERNS
