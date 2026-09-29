Updated: 2026-09-29

## Current focus
Stage H (S22-S29) is implemented and ticked end-to-end by an autonomous overnight run
(`scripts/run-overnight.sh`). Awaiting the stage-boundary review, not more building.

## Blocked
- Nothing hard-blocked. The S18 redis assertion carried from S22 is still unamended
  (needs approval to edit a file under `scripts/checks/`).

## Done (verified)
- S23-S29 ticked (check + review). Overnight run exit 0 at 07:56, 49 commits on `main`
  since the S23 tick (`f39fb33..9e504f8`), tree clean.
- S29 gate green in `docs/evidence/S29.log`: U1-U13 asserted live, `make jit-verify`
  J1-J11 PASS, `make verify NS=voting-a` 17 PASS, 0 FAIL.
- S23 spike: redis and postgres replaces <=1s; 50 of 50 queued votes lost across a redis
  replace; vote/worker reconnect; `call_runner` does not block the kopf loop (kopf 1.44.6
  offloads via `run_in_executor`). Verdict `maxmemory mutable` per the human's downtime
  decision, recorded in `docs/decisions/0007-maxmemory-mutable-despite-replace-cost.md`.
- Autonomy tooling committed: `scripts/run-overnight.sh` and
  `.opencode/agents/{implementer,reviewer}.md`. The script self-execs under `caffeinate`,
  gates on a PASS in `docs/evidence/SNN.log` and the reviewer's verdict, and passes on
  `CLEAR` or `CONCERNS` with an empty Blockers section.
- Model policy: exactly two, no per-step exceptions -
  `opencode-go/deepseek-v4.1-flash` (implementer) and `opencode-go/mimo-v2.6-flash`
  (reviewer); hardcoded at `scripts/run-overnight.sh:49-50`.

## Checkpoints
- Stage-H child checkpoints S23-S29 all pass on the current tree; S29's gate is the
  end-to-end one. Nothing pending.

## Next step
Run the RUNBOOK stage-boundary (`RUNBOOK.md` "At the stage boundary"): cold teardown
(`make jit-down`, then the cold order), a cumulative stage review by the strongest model,
then read one file at random yourself.

## Watch out
- **15 new ADRs, 0008-0022; 10 amend frozen checkpoints.** 6 checkpoints changed
  (S24-S29, +174/-67). Each amendment has an ADR and was reviewed, but the volume is the
  thing the stage review must judge - some are harness bugs, some reword an assertion to
  fit the code.
- **Every S23-S29 verdict is CONCERNS, never CLEAR.** Per `docs/build-plan.md` only CLEAR
  counts as done; the tracker is ticked on the experiment's looser "no blockers" bar and so
  overstates the repo's own standard.
- **S22's `review` box is still unticked** (its findings say CLEAR; it was never in the run).
- The run's S26-S29 reviews used `deepseek-v4-pro`, now disallowed; the two-model rule
  applies going forward only.
- **ADR 0007 is binding:** redis `maxmemory` is mutable; an annotation-driven infra change
  is explicit approval for any downtime. Its review concerns are not yet wired: add it to
  S26's Read list, and add the two S28 invalidation rows the ADR promises
  (`declarers-and-consumers.md:100` criterion 1; the stale `:161` step-0 spike line).
- **A bash checkpoint cannot prove a log's numbers were measured.** S23's `mutable` verdict
  is a human decision recorded in ADR 0007, not a measured result - do not treat the log as
  evidence it was measured.
- gnhf was trialled and parked: it drives `opencode serve`, but on a heavy objective the
  worker never emitted the structured JSON gnhf requires ("OpenCode produced no final
  answer"). The shell orchestrator was kept instead.

## Carried (still true)
- Existing namespaces created before Stage H may hold Secrets without the new keys; a pod
  redeploy needs the Secret patched or the namespace recreated.
- `app/*/Dockerfile` COPYs templates into the image: a template edit needs a rebuild.
- `console/serve.py` writes runs to `docs/evidence/console-<name>.log`; the browser suite
  redirects `serve.EVIDENCE` to a temp dir - keep that swap.
- pgadmin's lease is on `vote` deliberately; moving it breaks the orphaning demo.
- `refs/cline/checkpoints/*` snapshot `.env` and `terraform.tfstate`; never
  `git push --all`/`--mirror`.
- CRD `status` schema is a closed list; app env vars resolve at container start.
