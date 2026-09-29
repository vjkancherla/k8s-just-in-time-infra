# S23 Review

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: CONCERNS

Prompt intact: yes — twelve numbered questions, counted. Range under review
`4fd26b9..b7c6650` (8 commits, 6 files, +1296/-5: `docs/decisions/0007-…`,
`docs/evidence/S23.log`, `docs/evidence/s23-spike.log`, `docs/evidence/s23-spike.sh`,
plus the two review-machinery files the prompt exempts from rule 4). HEAD is
`5808c1a` (the prompt commit); no commit in the range amends `scripts/checks/`,
`scripts/checkpoint.sh`, `.clinerules/`, CI or scanner config, so the frozen-
checkpoint ADR rule is not engaged beyond judging ADR 0007 itself. I ran
`scripts/checkpoint.sh 23 /tmp/S23-review.log` privately — committed evidence
untouched. My first invocation (`… S23`) failed because the runner takes `23`,
my error, no repo side effect.

## Blockers

None.

Q1-Q5 mechanical record:

1. Nothing under `scripts/checks/`, `.clinerules/`, CI or scanner config:
   `git diff --name-only 4fd26b9..b7c6650 -- docs/todo.md scripts/checks/
   scripts/checkpoint.sh .clinerules/ .github/` is empty. The checkpoint scripts
   were frozen at `d0d4329` (S22) and are untouched here; no checkpoint created,
   reworded or weakened.
2. No dependency added: no manifest, requirements, Makefile or module change in
   the range. `docs/evidence/s23-spike.sh` uses python3/tofu/docker/kubectl/
   `redis-cli`-in-container — the repo's existing evidence-script toolchain
   (`docs/evidence/race-test.sh`).
3. Nothing deleted or weakened. `scripts/checks/S23.sh` is byte-identical across
   the range; the only assertion-adjacent rewrite is `docs/evidence/S23.log`
   going FAIL → PASS, which is the capture itself (`4fd26b9` held S22's
   "s23-spike.log missing" FAIL).
4. No file created or edited outside the named list. The three untracked
   `docs/evidence/overnight-20260928T232512Z.*` files in the working tree are
   the orchestrator's session log, outside the range (Notes).
5. `docs/todo.md` untouched; S23's boxes are still `- [ ] check  - [ ] review`
   (`docs/todo.md:123`).

Q6: `scripts/checks/S23.sh` passes on my clean run — `scripts/checkpoint.sh 23
/tmp/S23-review.log` → "PASS S23: spike measured (both replaces, vote loss,
reconnect), verdict: VERDICT: maxmemory mutable", and `bash scripts/checks/S23.sh`
exits 0 directly. The committed capture (`docs/evidence/S23.log`) records the same
line, run at `0889a9d` with 5 pending changes (those changes are `b7c6650`); my run
at HEAD confirms the PASS still holds over the final state, so the capture-vs-head
gap is a freshness note, not leftover state.

Q7: per the prompt's ADR-0007 note I did not turn the log-only gate into a
blocker; I judged ADR 0007 as a decision. Its reasoning is sound within its
disclosed limits and its scope is correct — see the Checkpoint assessment. The
findings below are reachability, provenance and citation issues, not a defect in
the decision.

## Concerns

1. **ADR 0007's obligations are still unwired from the step that must obey them**
   (carried forward; recorded, not closed). The ADR now says so itself — "Before
   S26 starts, ADR 0007 must be added to S26's reading"
   (`docs/decisions/0007-…md:90-95`) — but nothing has been done: S26's **Read**
   list is still "design note §Resolution rules, §Mutability contract, §Update
   flow, §Conditions; `jit-controller/main.py`…" (`docs/build-plan.md:926-929`)
   with no ADR 0007, and a repo-wide grep for `0007` hits only the ADR, the spike
   script/log, ADR 0006:91 and the review files — never `docs/build-plan.md`,
   `docs/designs/` or `docs/lessons.md`. S26 would code criterion 1's literal
   "adds or tunes, never removes data" (`docs/designs/declarers-and-consumers.md:100`)
   and emit `UpdateRefused` on exactly the key U1 (`:223`) requires to be applied.
   **Action:** orchestrator adds ADR 0007 to S26's reading before S26 starts, and
   adds the two S28 invalidation rows the ADR promises (`design:100` criterion 1
   and the stale `design:161` "step 0 spike" line) to the table at
   `docs/build-plan.md:996-1007`, which has no such row yet.
2. **The probe hardening that closed the previous concern 2 has no captured run.**
   The committed `docs/evidence/s23-spike.log` was last regenerated in `6fa2dcc`;
   `b7c6650` then hardened `s23-spike.sh` (rollout rc-check, empty worker/vote pod
   guards, both healthchecks `die` on FAILED, 30s drain rc-check, temp-file +
   `mv` publish, `S23_SPIKE_LOG` redirect) **without regenerating the log** —
   which the prompt sanctions under the human directive of 2026-09-28. The
   claimed end-to-end validation of the hardened script ("reproduced 0.81s /
   0.85s, 50/50, both reconnects OK") exists only as prose in `b7c6650`'s commit
   message; no artefact in the repo records it. **Action:** capture that run
   (`S23_SPIKE_LOG=/tmp/… docs/evidence/s23-spike.sh` output, or a one-line
   trailer in `docs/evidence/S23.log`) so the fix for "a FAILED reconnect still
   gates green" is evidenced rather than asserted.
3. **The evidence log carries no script provenance.** Neither `s23-spike.log` nor
   `S23.log` records which version/hash of `s23-spike.sh` produced the numbers, so
   a reader cannot tell whether the committed measurement came from the
   pre-hardening or post-hardening probe — the two concerns above are only
   discoverable by reading commit history. **Action:** one header line in the
   probe (`log "# probe $script_sha"` or similar) naming the script that wrote
   the log.
4. **ADR 0007's U7 citation is imprecise.** The ADR says "removing a database,
   renaming `postgres_db` or changing the password remain refused (U7)"
   (`0007-…md:75-77`), but U7 covers only the first two
   (`docs/designs/declarers-and-consumers.md:229`); `postgres_password` is
   refused by the table row at `:109` and stated at `:205`. The scope claim
   (nothing besides `maxmemory` is relaxed) is correct; the locator is not, and
   whoever wires S29's assertions from U7 will not find password coverage under
   it. **Action:** cite `:109` for the password refusal alongside U7.

## Notes

- The prompt's Q6 note states the committed numbers as "redis 0.81s, postgres
  0.85s". The committed log says **0.84s** and **0.90s** total
  (`docs/evidence/s23-spike.log:156, 396, 529-530`), which is what ADR 0007 quotes
  (`0007-…md:12-16`). 0.81/0.85 are the /tmp validation-run figures from
  `b7c6650`'s message. Prompt defect, not an implementer defect — recorded so the
  next reviewer does not chase it.
- The gate is a gate on the artefact forever: once `s23-spike.log` exists,
  S23.sh can only fail if the log is edited, and a probe run that `die()`s leaves
  the old log in place (by design — the `mv` publish at
  `s23-spike.sh:312-313`). S23.sh's greps also accept any digits
  (`votes lost 0 of 0` would match). Frozen, and the prompt bars turning the
  paperwork gate into a blocker; recorded for the record.
- The probe's "code reading" lines (`s23-spike.sh:104-108`: "handle_deployment is
  a synchronous def (line 129)", "invocation.py line 134") are typed prose, not
  asserted. They are accurate today — verified: `main.py:129` is a sync `def`,
  `:352` is the `call_runner` call, `:473/:488` the blocking `requests.post`,
  `:816` the sync timer, and there is no `async def` handler anywhere — but a
  future async conversion would still print "sync def (line 129)" on a rerun; the
  rc-checked probe proves only that *a* sync handler offloads to an executor.
- Design `:161` is satisfied, not contradicted: it is conditional ("If it is a
  synchronous call inside an `async` kopf handler…"), the spike established the
  sync-handler case, so `asyncio.to_thread` is correctly not applied;
  `jit-controller/main.py` is untouched across the range. The residual executor
  ceiling (`max_workers=6`, `s23-spike.log:10`) is disclosed in the log and the
  ADR and parked on S26 — correct placement, but it inherits concern 1's wiring
  gap.
- Design `:201-205` asks that the queue-loss and refusal facts reach tenants "in
  the module docs and the console". ADR 0007 assigns module-docs recording to S28
  and disclaims the console with a correct citation of build-plan S28's
  "Deliberately untouched" row (`build-plan.md:1006`). Defensible, but it is the
  ADR overriding the design's text — worth a glance from whoever signs S28.
- The postgres "settings path" was measured by patching a `/tmp` copy of the
  module (`s23-spike.sh:232-242`), because the module has no `settings` var until
  S27. The log labels it honestly; the spike did not exercise the code S27 ships.
- Hardcoded `ROOT`, `DOCKER_HOST`, MinIO keys and container IPs
  (`s23-spike.sh:17-29`) match the repo's convention (`race-test.sh`,
  `deploy/.env`), so no new secret; but the IPs are never validated against the
  running containers, so a stack rebuilt at a different address would be silently
  re-addressed by the probe.
- `docs/evidence/README.md` indexes every other probe and has no S23 row; not in
  this step's allowed list, correctly not edited — flag for the next evidence-
  index edit.
- `scripts/checks/S23.sh` is mode `100644` while the Stage-Z checks are `0755`
  (all S23-S29 are). `checkpoint.sh` invokes it with `bash`, so no impact; a
  frozen S22 artefact, outside this range.
- The three untracked `docs/evidence/overnight-20260928T232512Z.*` files are the
  orchestrator's run log; they must not be swept into a later commit as step
  evidence.

## Checkpoint assessment

`scripts/checkpoint.sh 23 /tmp/S23-review.log` passed on my clean run — exit 0,
"PASS S23: spike measured (both replaces, vote loss, reconnect), verdict:
VERDICT: maxmemory mutable" — and `bash scripts/checks/S23.sh` exits 0 directly,
matching the implementer's capture in `docs/evidence/S23.log`. It asserts the
step's goal at artefact level exactly as `docs/build-plan.md:867-870` specifies:
the log exists, carries a redis and a postgres replace time with units, a
lost-votes count, a reconnect observation, the `call_runner` blocking verdict,
and a final `VERDICT:` line of one of the two allowed values. It would still pass
if the probe were deleted outright (it greps only the committed log); the prompt
directs me to treat that as the designed paperwork gate over the human-run
protocol and to judge ADR 0007 instead, which I did. The ADR's reasoning is sound
within its own disclosed limits — the ≤1s figures are labelled container-replace
wall time only, explicitly excluding resync/runner/client latency
(`0007-…md:26-30`); the 50-of-50 loss is stated plainly and overridden by an
explicit annotation-as-downtime-approval decision; the reconnect evidence is
honestly downgraded to fresh-pod startup plus per-request reachability, with the
un-exercised in-place `RedisError` path called out as *not* established; and the
event-loop verdict is backed by a rc-checked probe printing `separate executor
thread: True` with the pool ceiling disclosed. Its scope is correct: redis
`maxmemory` only, with remove-database, `postgres_db` rename and password
refusals expressly untouched (design `:106/:108/:109` unchanged), no v2 design
round, no console obligation. No blocker; four concerns, of which 1 must close
before S26 starts and 2 before anyone trusts the hardened probe.

Verdict: CONCERNS
