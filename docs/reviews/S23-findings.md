# S23 Review

Reviewer model: mimo-v2.6-flash (opencode-go/mimo-v2.6-flash)
Verdict: CONCERNS

Prompt intact: yes — twelve numbered questions, verified by count. Range under
review `4fd26b9..7a614fc` (one commit, 4 files, +856/-5, all four inside the
step's named scope). I ran `scripts/checkpoint.sh 23 /tmp/S23-review.log`
privately so committed evidence was untouched; my first invocation (`... S23`)
failed only because the runner expects `23` — usage per `scripts/checkpoint.sh:7`,
my error, no repo side effect.

## Blockers

None.

Q-by-Q mechanical record:

1. Nothing under `scripts/checks/`, `.clinerules/`, CI or scanner config in the
   range — `git diff --stat 4fd26b9..7a614fc` lists exactly `docs/decisions/0007-…`,
   `docs/evidence/S23.log`, `docs/evidence/s23-spike.log`,
   `docs/evidence/s23-spike.sh`. `scripts/checkpoint.sh 23` also re-checked
   `scripts/checks/S23.sh` for uncommitted edits and found none (frozen check
   passed). No checkpoint created or reworded.
2. No dependency added: no manifest, module, requirements or Makefile change.
   The probe uses python3/tofu/docker/kubectl, already the repo's evidence-script
   toolchain (`docs/evidence/race-test.sh` et al.).
3. Nothing deleted or weakened. `scripts/checks/S23.sh` is untouched; the only
   rewrite is `docs/evidence/S23.log` going FAIL → PASS, which is the capture.
4. No file created or edited outside the named list. The three untracked
   `docs/evidence/overnight-20260928T232512Z.*` files are the orchestrator's run
   log (see Notes), not part of the diff.
5. `docs/todo.md` not touched; no review box ticked.

Q6: `scripts/checks/S23.sh` passes on my clean run (0 pending changes, commit
58b122b) and passes the committed capture the implementer produced.
Q7: per the prompt's ADR-0007 instruction I did not turn the paperwork gate into
a blocker; I judged the ADR instead — scope correct, reasoning sound with the
qualifications recorded below.

## Concerns

1. **The "worker reconnect" observation is a pod the spike itself deleted.**
   `docs/evidence/s23-spike.sh:107` scales the worker to 0 before the replace and
   `:147` scales it back to 1, so the log's rollout (`s23-spike.log:153-157`,
   "0 out of 1 new replicas") and `:159` are a *fresh* pod starting, not a
   long-lived client surviving the container replace. `vote` was not restarted,
   so `:160` is a genuine in-place check — but `_redis()` builds a new client per
   request (`app/vote/app.py:20-21, 56-62`), so it proves reachability of the new
   container, not re-establishment of an existing connection. ADR 0007 states
   flatly "`vote` and `worker` reconnect to the recreated containers"
   (`0007-…md:16-17`). The in-place worker path exists only in code
   (`app/worker/app.py:109-112`, reconnect on `RedisError`). Fix: state the
   limitation in the ADR, or take one measurement with the worker left running
   across the replace.
2. **The verdict block's arithmetic double-counts.** `RSR`/`PSR` are
   `t_ready - t0`, i.e. *total* wall time (`s23-spike.sh:132-134, 212-214`), but
   the verdict prints them as "start" (`:237-238`): `s23-spike.log:516-517` reads
   "redis replace <=1s (apply 0.79s **+ start 0.86s** …)" and the ADR repeats it
   (`0007-…md:12-15`). Added up, the line says 1.65s while the headline it
   supports says <=1s. The `<=1s` claim itself is correct (0.86s / 0.84s total,
   rounded up by `RSI`/`PSI`); only the labels are wrong. Fix: label `RSR`/`PSR`
   as total, or compute start as `t_ready - t_apply`.
3. **The `call_runner` verdict line is typed, not derived.**
   `s23-spike.sh:90` writes "call_runner does not block the kopf event loop"
   unconditionally, and the probe it rests on (`:84`) is not rc-checked — the
   script runs `set -uo pipefail` with no `-e` (`:15`), so a failed
   `kubectl exec` would still leave the verdict in the log and S23.sh would still
   grep it (`scripts/checks/S23.sh:25-26`). I re-verified the substance
   independently inside the controller pod — kopf 1.44.6,
   `invocation.py:134 future = loop.run_in_executor(executor, real_fn)`,
   probe reports "separate executor thread: True", `main.py` has no `async def`
   handler — so the *conclusion* is right; the artefact just cannot fail when the
   probe does. The follow-on claim "the 30s resync keeps ticking while an apply
   runs" (`s23-spike.log:15-17`) is an inference from thread identity; no timer
   was observed firing during an apply.
4. **Concurrency against the shared handler pool is unmeasured.** Kopf's default
   `settings.execution.executor` on this host is a `ThreadPoolExecutor` with
   `max_workers = 6` (verified in the controller pod; `main.py` sets no
   `OperatorSettings`), shared by every sync handler — `handle_deployment`
   (`main.py:129`), the sync `@kopf.timer` resync (`:815-816`) and the delete
   handler. Six simultaneous 600s `call_runner` applies occupy the whole pool and
   the resync queues behind them: the exact failure the design dreads
   (`declarers-and-consumers.md:161`, "the 30s resync stops with it"), arriving
   through the pool instead of the event loop. The spike's "resync keeps ticking"
   claim holds only below the cap; neither the design nor the checkpoint covers it.
5. **ADR 0007 schedules an obligation the plan forbids.** "`[t]he module docs and
   the console must say so`" (`0007-…md:48-49`) versus build-plan S28's row
   "`console page + make state` | no change … **Deliberately untouched**"
   (`docs/build-plan.md:1006`) and the Stage-H scope fence that puts the console
   out of scope. Module docs are covered by S28 (`:1011-1013`); the console clause
   is not scheduled anywhere. Fix: drop it from the ADR or record it explicitly as
   out-of-stage.
6. **Nothing schedules ADR 0007's supersession into the design that S26 codes
   from.** The design's criterion 1 still says "adds or tunes, **never removes
   data**" (`declarers-and-consumers.md:100`) — which, as the ADR itself argues
   (`0007-…md:22-23`), refuses `maxmemory` — while the table one paragraph above
   already lists it mutable with "queue contents lost" (`:105`). The ADR
   supersedes "the spike's criterion-1 *refused* reading" (`:50`) but
   `docs/designs/` is read-only for S23, and S28's invalidation table
   (`docs/build-plan.md:996-1007`) has no row for it. S26 implements "the
   mutability contract" from §Mutability contract (`:936`) and could implement
   either branch; U1 (`:1033`) depends on the mutable one. Add the amendment
   (design line 100/105 and S28 row) before S26 starts, or the ADR and the
   design disagree at exactly the point the code is written. Related staleness:
   `declarers-and-consumers.md:161` still reads "the step 0 spike confirms which
   case applies" after it has confirmed.
7. **Checkpoint strength and evidence durability** (raised for the record; the
   prompt bars turning the paperwork gate itself into a blocker). S23.sh accepts
   any digits — `redis replace: 0s`, `votes lost 0` both grep clean
   (`scripts/checks/S23.sh:17-22`) — and a single word `reconnect` (`:23-24`),
   and accepts either verdict (`:31-36`). A flaky run therefore passes: if
   `kubectl scale --replicas=0` fails, the wait loop times out after 60s and the
   script continues (`s23-spike.sh:106-111`, no `-e`), a live worker could drain
   the queue, and "votes lost 0 of 50" would be recorded as a measurement and
   still gate green. Separately, the script's first act is `: > "$LOG"` (`:32`),
   so any accidental rerun of the probe destroys the committed artefact S23.sh
   gates on, with no "log exists" guard.
8. **ADR cites an artefact that no longer exists.** "the spike's own first
   reading did [refuse]" (`0007-…md:23`) — the log is truncated and regenerated
   by every run, and the script now hardcodes `VERDICT: maxmemory mutable`
   (`s23-spike.sh:254`), so the refused reading is unrecoverable from the repo.
   Either point at where it survives (session log, ADR discussion) or drop the
   clause; as written the ADR's central "the probe refused first, the human
   overrode it" narrative is unverifiable.

## Notes

- Hardcoded absolute `ROOT` and `DOCKER_HOST` (`s23-spike.sh:17, 30`) match the
  repo's existing evidence-script convention (`race-test.sh:5`, `s17-cold-path.sh:29`),
  so not a portability finding here.
- The trailing side-finding block (`s23-spike.log:530-534`) — every re-apply of
  the stock module plans a replacement because `ports.external` round-trips
  `0 -> <assigned>` — is outside S23's measurement but flags that S27/U2's
  "container ID unchanged" assertion (`build-plan.md:978, 1034`) may be at risk
  unless the module is fixed. Recorded honestly as "not this step's checkpoint".
- Postgres answers `pg_isready` 0.08s after apply-return (`s23-spike.log:383`,
  total 0.84s vs apply 0.76s); fast but plausible against a warm persistent data
  dir (no initdb). The ADR's "Seconds" conclusion does not hinge on it.
- `claim_lock` is a `threading.Lock` (`main.py:31-55`), so S26 need not convert
  handlers to `async def` — the spike's caveat that `asyncio.to_thread` becomes
  required "only if S26 converts the handler to async def"
  (`s23-spike.log:17`) stays hypothetical as the code stands.
- The untracked `docs/evidence/overnight-20260928T232512Z.*` files are the
  orchestrator's own run log (first line "autonomous overnight run … steps='23'"),
  predating and surrounding this commit; they should not be swept into a
  later commit as if they were step evidence.

## Checkpoint assessment

`scripts/checkpoint.sh 23 /tmp/S23-review.log` passed on my clean run: exit 0,
"PASS S23: spike measured (both replaces, vote loss, reconnect), verdict:
VERDICT: maxmemory mutable", 0 pending changes at commit 58b122b — the same line
the implementer captured in `docs/evidence/S23.log`. It asserts the step's goal
at artefact level exactly as `docs/build-plan.md:867-870` specifies: the log
exists, contains a redis and a postgres replace time, a lost-votes count, a
reconnect observation, the `call_runner` blocking verdict, and a final
`VERDICT:` line of one of the two allowed values. What it cannot do is check any
number's range, which app reconnected, or whether the log was measured rather
than written (concerns 3 and 7) — that is the paperwork gate over the human-run
protocol the prompt tells me to accept, so I judged ADR 0007 instead. Its scope
is correct: `maxmemory` only, with remove-database, `postgres_db` rename and
password-change refusals expressly untouched (`0007-…md:50-52`), consistent with
U7. Its reasoning is defensible on the measurements that exist (<=1s replaces,
50-of-50 loss disclosed, vote-loss acceptance stated in Consequences) but
overstates the reconnect evidence (concern 1), mislabels the timing arithmetic
(concern 2), creates an unschedulable console obligation (concern 5), leaves the
supersession unwritten in the design S26 reads (concern 6), and cites a
first-reading artefact the repo no longer holds (concern 8). No blocker; six
actionable concerns before S24-S26 build on this.

Verdict: CONCERNS
