# S22 - declarers and consumers - working rules

These apply to every session working on Stage H of `docs/build-plan.md`
(`docs/designs/declarers-and-consumers.md`), alongside `.clinerules/01-jit-poc.md`.

```json
{ "instructions": [".opencode/rules/*.md"] }
```

## Scope

- Stage H is steps S22-S29 in `docs/build-plan.md`. Nothing outside them.
- `docs/designs/` and `docs/lessons.md` are read-only except where step S28 names
  the exact amendments. If you think more needs editing there, stop and say so.
- `.clinerules/`, `console/`, `scripts/verify-jit.sh` and the J/R suites are out of
  scope: a change breaking them is a finding, not your job to fix here.

## Method

- One step at a time; read only the files the step lists; stop after emitting the
  review prompt.
- **Run checkpoints only through `scripts/checkpoint.sh SNN`.** It captures the run
  to `docs/evidence/SNN.log`; a typed PASS does not survive the session boundary.
- Commit the code and that log in the same commit. Never edit a captured log.
- `scripts/checks/` and `scripts/checkpoint.sh` are frozen. A checkpoint changes
  only through an approved ADR (`docs/decisions/0000-template.md`), committed with
  the edit and cited in the review prompt.
- The design's defaults are live even where the build plan does not restate them:
  `params: {}` declares defaults; missing `params` consumes; consumers never get
  promoted; failure keeps phase `Ready`, never `Deleting`; `appliedParams` never
  carries credentials; one apply per handler; `softDeleteTTL` is the declared
  maximum, a spec patch with no runner call.
- The spike (S23) may drop redis `maxmemory` from the mutable surface. If it does,
  stop: the design gets a v2 and the human approves before anything is built on it.

## Known traps (from this repo's lessons, binding)

- A runner call inside a kopf handler can block the event loop for 600s — S23's
  spike measures this; the fix is `asyncio.to_thread`, not a margin.
- The CRD `status` schema is a closed list; new status fields need a CRD edit or
  the API server prunes them.
- App env vars resolve at container start: a Secret change needs an app restart —
  that is the advisory `AppRestartRequired`-style condition, never a controller
  restart.
- `tofu state rm postgresql_*` before destroy, and the postgres volume always goes
  with its container.
- Templates are baked into the runner image at build: a module edit needs a rebuild.

## When something is ambiguous

Ask. One question, then wait. Do not guess and proceed.

---

## Why each rule earns its place

| Rule | The failure it prevents |
|---|---|
| Scope fence (console, J/R suites) | Stage H quietly rewriting the suite that gates it |
| One step at a time | The 2-day controller core sprawling into modules and docs |
| Frozen checkpoints + ADR path | A gate reworded to fit the code after it failed |
| Evidence in the same commit | A pass that says nothing about the range under review |
| Consumer-promotion ban | A Deployment delete silently re-applying someone else's params |
| `appliedParams` sans credentials | Status readable by anyone who can get infraclaims |
| Spike decides maxmemory | Building U1 on a replace cost nobody measured |
