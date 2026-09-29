# S23 Review

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: CONCERNS

Prompt intact: yes — twelve numbered questions, counted. Range under review
`4fd26b9..6fa2dcc` (4 commits, 6 files, +1238/-5: `docs/decisions/0007-…`,
`docs/evidence/S23.log`, `docs/evidence/s23-spike.log`,
`docs/evidence/s23-spike.sh`, plus the two review-machinery files the prompt
exempts from rule 4). HEAD is `cccd035`; no commit in the range amends anything
under `scripts/checks/` or `scripts/checkpoint.sh`, so no ADR under the frozen-
checkpoint rule is in play beyond ADR 0007 itself. I ran
`scripts/checkpoint.sh 23 /tmp/S23-review.log` privately; committed evidence
untouched. My first invocation (`… S23`) failed only because the runner takes
`23` (`scripts/checkpoint.sh:7`), my error, no repo side effect.

## Blockers

None.

Q1-Q5 mechanical record:

1. Nothing under `scripts/checks/`, `.clinerules/`, CI or scanner config:
   `git diff --name-only 4fd26b9..6fa2dcc` lists exactly the six files above.
   `checkpoint.sh 23` also re-checked `scripts/checks/S23.sh` for uncommitted
   edits and found none. No checkpoint created or reworded.
2. No dependency added: no manifest, module, requirements or Makefile change.
   The probe uses python3/tofu/docker/kubectl/`redis-cli`-in-container — the
   repo's existing evidence-script toolchain (`docs/evidence/race-test.sh`).
3. Nothing deleted or weakened. `scripts/checks/S23.sh` is untouched across the
   range; the only rewrite of an assertion-adjacent artefact is
   `docs/evidence/S23.log` going FAIL → PASS, which is the capture itself.
4. No file created or edited outside the named list. The three untracked
   `docs/evidence/overnight-20260928T232512Z.*` files in the working tree are
   the orchestrator's own run log, outside the range (Notes).
5. `docs/todo.md` untouched; both S23 boxes still `[ ]`
   (`docs/todo.md:123`).

Q6: `scripts/checks/S23.sh` passes on my clean run (exit 0, 0 pending changes,
commit `cccd035`) and matches the implementer's capture
(`docs/evidence/S23.log`, run at `dbb2df0`, probe started 23:45:10Z, checkpoint
23:46:27Z — same artefact, committed with its code in `6fa2dcc`).

Q7: per the prompt's ADR-0007 note I did not turn the log-only gate into a
blocker; I judged ADR 0007 as a decision. Reasoning sound within its own
disclosed limits, scope correct — see the Checkpoint assessment. The remaining
findings are forward-reachability and probe-robustness issues, not a defect in
the decision.

## Concerns

1. **ADR 0007's obligations are unreachable from the step that must obey them.**
   The ADR states "`docs/designs/` is read-only in S23, so this ADR — not the
   design note — is the authority until S28. S26 must implement `maxmemory` as
   mutable (U1) and must not take criterion 1's 'refused' branch"
   (`docs/decisions/0007-…md:74-79`). Nothing routes S26 to it: `git grep 0007`
   hits only the ADR, the spike script/log and ADR 0006:91 — not
   `docs/build-plan.md`, whose S26 **Read** list is "design note §Resolution
   rules, §Mutability contract, §Update flow, §Conditions; `jit-controller/main.py`…"
   (`docs/build-plan.md:926-929`). S26 codes "the mutability contract" from
   §Mutability contract, whose criterion 1 still reads "adds or tunes, **never
   removes data**" (`docs/designs/declarers-and-consumers.md:100`) while its own
   table one paragraph down already lists `maxmemory` mutable with "queue
   contents lost" (`:105`). An implementer reading the criteria as guards
   implements `UpdateRefused` on exactly the key U1 (`:223`) and S29 U1
   (`build-plan.md:1033`) require to be applied. Fix: cite ADR 0007 in the S26
   session's reading/prompt the same way this prompt cites it, or have the plan
   owner add one line to build-plan S26; and remember the ADR's own S28 row
   obligation (`build-plan.md:996-1007` has no row for it yet) will need the
   same sanction when S28's scope list is generated.
2. **The probe records a *failed* reconnect and still gates green.**
   `docs/evidence/s23-spike.sh:176-188` runs the worker healthcheck and the
   vote `/healthz` as `if … then log "… OK" else log "… FAILED" fi` with no
   `die`, and `:195` logs "the restarted worker drained a post-replace vote"
   unconditionally, appending whatever `LLEN votes` happens to be. The frozen
   gate's only reconnect assertion is the bare word
   (`scripts/checks/S23.sh:23-24`, `grep -qi reconnect`), so a worker that fails
   to reconnect after a real `maxmemory` edit produces a log that passes S23
   unchanged. `:174` (`kubectl rollout status`) is likewise not rc-checked and
   `W_POD` can be empty, which lands in the FAILED branch. S23.sh is frozen, so
   the fix belongs in the probe: `die` on either FAILED branch and on a
   non-zero post-replace `LLEN`.
3. **The port-drift side finding is material to S27/U2 and lives nowhere but
   the spike log.** `docs/evidence/s23-spike.log:545-549` records that every
   re-apply of the stock module plans a replacement even with unchanged params
   (`ports { external = 0 }` round-trips `0 -> <assigned>`), and that S27's
   databases-only update (U2: "container ID unchanged") needs the module fixed
   or the container is replaced on every apply. That collides with
   `build-plan.md:978` and `:1034`. It is not in ADR 0007, not in
   `docs/lessons.md` (which *was* in this step's allowed list), not in the
   build plan. A 550-line log is where a later step will not look. Fix: carry
   the one paragraph into `docs/lessons.md` or ADR 0007 before S27 starts.
4. **Any rerun of the probe destroys the committed evidence the gate reads.**
   First act of `docs/evidence/s23-spike.sh:32` is `: > "$LOG"` with no
   "log exists" guard; a run that dies at preflight (`:53-59`) leaves a file
   containing only `FAIL: …`, and the next `scripts/checkpoint.sh 23` fails
   through no fault of the step, with the real measurement unrecoverable (the
   script hardcodes `ROOT` at `:17`, so it only runs on this machine anyway).
   Previously raised and still open. Fix: refuse to run if the log exists
   unless `--force` is passed, or write to a timestamped file and copy.
5. **"Downtime" in the ADR means container replace only, from one warm sample.**
   The Decision rests on "the replaces are <=1s" (`0007-…md:45-48`), measured as
   tofu apply + time-until-ping on one host with warm caches
   (`s23-spike.log:156`, `:396`: 0.84s and 0.90s). It excludes the controller
   noticing the annotation (up to a 30s resync), runner queueing and client
   retry — the parts a tenant actually experiences — and postgres answering
   `pg_isready` 0.07s after apply-return is at the fast edge of plausible
   (`:396`). The ADR does label the numbers "in the recorded run"
   (`0007-…md:12-16`), so this is a framing caveat: read "seconds", not "1s
   outage", when U1's tolerance is quoted in S26/S29.

## Notes

- The `VERDICT:` line is scripted, not derived: `s23-spike.sh:285` always writes
  `VERDICT: maxmemory mutable`, with the decision-overlay and provenance
  paragraphs immediately above it (`:269-284`) and the same statement in the log
  (`s23-spike.log:532-542`) and the ADR (`0007-…md:39-41, 50-53`). Disclosed
  three ways, so not a finding — but it means the build plan's "refused" verdict
  branch (`build-plan.md:864-865`) is no longer reachable through the sanctioned
  probe, and S23.sh still accepts either (`S23.sh:31-36`).
- S23.sh accepts any digits (`redis replace: 0s`, `votes lost 0` grep clean,
  `S23.sh:17-22`). Frozen, and the prompt bars turning the paperwork gate itself
  into a blocker; recorded here for the record.
- Design line 161 says "Run it with `asyncio.to_thread` (the step 0 spike
  confirms which case applies)" — the case that applies is the *sync*-handler
  one, because `jit-controller/main.py` contains no `async def` handler at all
  (verified: only `@kopf.on.login`, `@kopf.on.create/update`, `@kopf.timer`,
  `@kopf.on.delete`, all `def`). The spike answered the design's actual
  question; the goal's broader parenthetical ("it must move to
  `asyncio.to_thread` if it does [run synchronously]") would require converting
  the handlers first. The residual pool ceiling (`max_workers=6`,
  `s23-spike.log:10`) is recorded and assigned to S26 — correct placement.
- ADR citation nit: the password-change refusal is attributed to U7
  (`0007-…md:69-71`), but U7 (`design:229`) names remove-database and
  `postgres_db` only; `postgres_password` is refused by the table row at
  `:109`. Same outcome, wrong locator.
- `docs/evidence/README.md` indexes every other probe (`race-test.sh`,
  `leak-probe*.sh`, `s17-*`) and has no S23 row for `s23-spike.sh`/`.log`. Not
  in this step's allowed list, so correctly not edited — flag it for whoever
  sanctions the next evidence-index edit.
- Hardcoded `ROOT`, `DOCKER_HOST` (`s23-spike.sh:17, 30`), MinIO keys
  (`:43-44`) and the container IPs (`:25-26`) match the repo's existing
  convention (`race-test.sh`, `deploy/.env`, `jit-runner/main.py`), so no new
  secret and no portability finding — but the IPs are never validated against
  the running containers, so a stack rebuilt at a different address would be
  silently re-addressed by the probe.
- The postgres "settings path" was measured by patching a `/tmp` copy of the
  module (`s23-spike.sh:216-224`), since the module's `settings` var does not
  exist until S27. Honest label in the log (`:296`, `:396`); worth remembering
  that the spike did not exercise the code S27 will ship.
- The three untracked `docs/evidence/overnight-20260928T232512Z.*` files are the
  orchestrator's run log predating and surrounding this range; they should not
  be swept into a later commit as step evidence.

## Checkpoint assessment

`scripts/checkpoint.sh 23 /tmp/S23-review.log` passed on my clean run: exit 0,
"PASS S23: spike measured (both replaces, vote loss, reconnect), verdict:
VERDICT: maxmemory mutable", 0 pending changes at `cccd035` — the same line the
implementer captured in `docs/evidence/S23.log`. It asserts the step's goal at
artefact level exactly as `docs/build-plan.md:867-870` specifies: the log
exists, carries a redis and a postgres replace time with units, a lost-votes
count, a reconnect observation, the `call_runner` blocking verdict, and a final
`VERDICT:` line of one of the two allowed values. It would still pass if the
probe were deleted outright (it greps only the committed log) — the prompt
directs me to treat that as the designed paperwork gate over the human-run
protocol, so I assessed ADR 0007 instead, and it holds: the reasoning matches
the measurements in the log (0.84s and 0.90s replaces, 50-of-50 loss stated
plainly, reconnect honestly downgraded to fresh-pod startup + per-request
reachability after the previous review, event-loop verdict backed by a
rc-checked probe printing `separate executor thread: True` and `max_workers=6`
with the pool ceiling disclosed and parked on S26), and the scope is correct —
redis `maxmemory` only, remove-database / `postgres_db` rename / password
refusals and the rest of the v1 surface expressly untouched, the console
obligation withdrawn, module-docs recording assigned to S28's existing Do bullet
(`build-plan.md:1011-1013`). No blocker; five concerns, of which 1 and 3 should
be closed before S26 and S27 respectively start.

Verdict: CONCERNS
