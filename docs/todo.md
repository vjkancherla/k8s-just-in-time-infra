# CI Pipeline — Tracker

Design: [./designs/ci-pipeline.md](./designs/ci-pipeline.md) ·
Plan: [./build-plan.md](./build-plan.md) ·
Rules: [../.opencode/rules/ci-pipeline.md](../.opencode/rules/ci-pipeline.md) ·
Runbook: [../RUNBOOK.md](../RUNBOOK.md)

One box per step. Tick it when `scripts/ci-checkpoint.sh CI<NN>` passes. Run logs live in
`docs/evidence/CI<NN>.log`; a step's outcome in `docs/steps/CI<NN>.md`; the stage's state
in `docs/stages/<stage>.md`.

## Stage A — The pipeline skeleton and the risky substrate

- [x] **CI01** — the fast half is green locally, and the runner can be dispatched — [plan](./build-plan.md#ci01-the-fast-half-is-green-locally-and-the-runner-can-be-dispatched)
- [x] **CI02** — a stock `ubuntu-24.04` runner can host the cluster's fixed network — [plan](./build-plan.md#ci02-a-stock-ubuntu-2404-runner-can-host-the-clusters-fixed-network)

## Stage B — Portability migration

- [ ] **CI03** — the repo builds and the R-suite can pass on amd64 — [plan](./build-plan.md#ci03-the-repo-builds-and-the-r-suite-can-pass-on-amd64)

## Stage C — The full e2e job

- [ ] **CI04** — the e2e job runs the cold path — [plan](./build-plan.md#ci04-the-e2e-job-runs-the-cold-path)
- [ ] **CI05** — the e2e job runs the console and J suites — [plan](./build-plan.md#ci05-the-e2e-job-runs-the-console-and-j-suites)

## Stage D — Report-only, hardened, documented

- [ ] **CI06** — the pipeline is report-only, hardened and written down — [plan](./build-plan.md#ci06-the-pipeline-is-report-only-hardened-and-written-down)

## Stage reports

- [ ] [Stage A](./stages/A.md)
- [ ] [Stage B](./stages/B.md)
- [ ] [Stage C](./stages/C.md)
- [ ] [Stage D](./stages/D.md)

## Decisions (settled)

- [x] One workflow file, two parallel jobs — `.github/workflows/ci.yml`
- [x] `ubuntu-24.04` pinned, not `ubuntu-latest`
- [x] Report-only: no required checks
- [x] The existing `make` suites are the checks; the pipeline wraps, never rewrites
- [x] Step ids `CI01`–`CI06` — outside the frozen Stage-H `S00`–`S29` range
- [x] The CI runner is `scripts/ci-checkpoint.sh`; the frozen `scripts/checkpoint.sh` is untouched
