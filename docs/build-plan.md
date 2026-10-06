# CI Pipeline — Build Plan

Design: [./designs/ci-pipeline.md](./designs/ci-pipeline.md) · Tracker: [./todo.md](./todo.md) ·
Rules: [../.opencode/rules/ci-pipeline.md](../.opencode/rules/ci-pipeline.md) ·
Runbook: [../RUNBOOK.md](../RUNBOOK.md)

6 steps in 4 stages. Each step is a slice that runs, with a check that proves it. Step ids
are `CI01`…`CI06`, deliberately outside the archived Stage-H range (`S00`–`S29`) so no
frozen checkpoint or evidence log is ever overwritten.

This is a map. Steps get reordered, merged, split or skipped as the build teaches us
things — each change is one line in the **Changes** log at the bottom.

## Stage A — The pipeline skeleton and the risky substrate

### CI01. The fast half is green locally, and the runner can be dispatched

**Goal:** the four pytest files and the lint pass on the current tree, and `gh` is
authenticated with the `workflow` scope — so the CI has a known-good baseline to
reproduce and a way to run it.
**Read:** `jit-controller/test_ipam.py`, `jit-controller/test_declarers.py`,
`console/test_serve.py`, `console/test_console.py`, `scripts/checks/lint-helpers.sh`,
`jit-controller/requirements.txt`.
**Do:** create a throwaway venv from `jit-controller/requirements.txt` (kopf, kubernetes,
requests) plus `pytest`; run the four suites and `lint-helpers.sh`; confirm
`gh auth status` shows the `workflow` scope. Record the exact pass counts — they become
the numbers the `fast` job asserts.
**Check:**
- V1 baseline · `test_ipam.py` exits 0
- V1 baseline · `test_declarers.py` exits 0 **with `requests` installed** (the repo's
  committed `.venv` lacks it)
- V1 baseline · `test_serve.py` and `test_console.py` exit 0
- V1 baseline · `scripts/checks/lint-helpers.sh` prints PASS
- `gh auth status` names the `workflow` scope

### CI02. A stock `ubuntu-24.04` runner can host the cluster's fixed network

**Goal:** a GitHub-hosted runner creates a k3d cluster on `172.19.0.0/16` and reaches a
container at a fixed `172.19.0.10` — no collision.
**Read:** `app/scripts/deploy.sh` (`:45`, the subnet), `deploy/runner.sh` (`:19`, fixed
`.10`), `deploy/minio.sh` (`:25`, fixed `.11`).
**Do:** write `.github/workflows/ci.yml` with the two-job skeleton and the three
triggers (`push` branches `[main]`, `pull_request`, `workflow_dispatch`) on
`ubuntu-24.04`; `fast` runs the four suites from CI01 plus `lint-helpers.sh`; `e2e` is a
probe only — install a pinned k3d via `curl`, create the cluster with
`--subnet 172.19.0.0/16`, start a busybox container at `172.19.0.10` on the k3d network,
and curl it from the host. Push the branch and open a PR (the `pull_request` trigger is
how the file runs before it is on `main`).
**Check:**
- V9 · `ci.yml` parses; exactly two jobs and the three triggers
- V1 · `fast` is green on the runner
- V2 · `e2e` creates the cluster on the subnet and reaches the fixed `.10` address
- V2 · the run is visible on the PR before anything lands on `main`

**If it fails:** stop. `172.19.0.0/16` or `.10`/`.11` collides on a stock runner. Change
the single `--subnet` argument (`app/scripts/deploy.sh:45`) and the fixed `.10`/`.11`
call sites (`deploy/runner.sh:19`, `deploy/minio.sh:25`) — never the 29 hardcoded
`172.19.0.x` references — then re-run V2 before continuing. If no free subnet keeps the
IPAM block scheme intact, that is a design change, not a plan change.

## Stage B — Portability migration

### CI03. The repo builds and the R-suite can pass on amd64

**Goal:** the runner image, the app image build, and the R15 gate no longer assume
arm64, so an amd64 job can build the stack and reach the J2 literal.
**Read:** `jit-runner/Dockerfile` (`:7`), `app/scripts/build.sh` (`:22`,`:28`),
`app/scripts/verify.sh` (`:333`,`:342`), `scripts/verify-jit.sh` (`:208`).
**Do:** the tofu URL becomes
`.../tofu_1.8.1_linux_$(dpkg --print-architecture).zip`; `build.sh` drops
`--platform linux/arm64` on **both** branches (registry and non-registry) so Docker
builds native; `verify.sh` checks at `:333` and `:342` stop letting `arch` decide R15 —
the architecture is still read and printed in the pass line, but no longer a conjunct.
**Check:**
- V3 · the tofu URL expands to `linux_amd64` on amd64 and `linux_arm64` on arm64
- V3 · a native build on this Mac still produces arm64 images (behaviour preserved)
- V3 · `bash -n` is clean on both edited scripts
- V5 · R15 no longer fails on a wrong-architecture image, but still fails on
  `ImagePullBackOff` / a missing registry ref
- V5 · `scripts/verify-jit.sh:208`'s `===== 17 PASS, 0 FAIL =====` is now reachable on
  amd64

| Existing check or script | Currently | Becomes |
|---|---|---|
| `jit-runner/Dockerfile:7` | hardcoded `linux_arm64` zip | arch from `dpkg --print-architecture` |
| `app/scripts/build.sh:22,28` | `--platform linux/arm64` on both branches | flag dropped; Docker builds native |
| `app/scripts/verify.sh:333` (registry) | `arch == arm64 && reg_refs >= 3` | `reg_refs >= 3`; arch printed, not asserted |
| `app/scripts/verify.sh:342` (local) | `arch == arm64 && imagepull == 0` | `imagepull == 0`; arch printed, not asserted |
| `scripts/verify-jit.sh:208` (J2) | literal `17 PASS` unreachable on amd64 | reachable, because R15 can pass |

## Stage C — The full e2e job

### CI04. The e2e job runs the cold path

**Goal:** the `e2e` job writes `deploy/.env`, builds `jit-controller:latest`, runs
`make test-up` to `17 PASS, 0 FAIL`, and uploads evidence on failure.
**Read:** `deploy/minio.sh`, `deploy/runner.sh`, `scripts/jit-up.sh`, `scripts/demo-up.sh`,
`docs/evidence/s17-cold-path-green.log`.
**Do:** replace the probe body with the cold path in order — write a `deploy/.env`
holding fixed throwaway `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`; `docker build -t
jit-controller:latest jit-controller/`; then `make test-up`. Add an `if: failure()`
`actions/upload-artifact` step for `docs/evidence/` and `app/.workflow/`. Leave the
`fast` job untouched.
**Check (live, `gh`):**
- V4 · the job writes `deploy/.env` before any MinIO step
- V4 · `docker build jit-controller:latest` succeeds on the runner
- V4 · `make test-up` completes and `make verify` reports `17 PASS, 0 FAIL`
- V7 · a deliberately failed run uploads the evidence artifact

### CI05. The e2e job runs the console and J suites

**Goal:** the `e2e` job also runs `make console-test` and `make jit-verify`, bounded by
a timeout.
**Read:** `Makefile` (`console-test`, `jit-verify`), `scripts/verify-jit.sh`.
**Do:** append `make console-test` and `make jit-verify` after `make test-up`; set
`timeout-minutes: 45` with a comment that it is a ceiling, not a measurement.
**Check (live, `gh`):**
- V6 · `make console-test` passes (server + contract; the browser suite skips)
- V5 · `make jit-verify` reports `11 PASS, 0 FAIL` (J1–J11)
- V7 · the whole job finishes inside the timeout

## Stage D — Report-only, hardened, documented

### CI06. The pipeline is report-only, hardened and written down

**Goal:** the pipeline cancels superseded runs, is confirmed non-blocking, and is
described where the next reader looks.
**Read:** `.github/workflows/ci.yml`, `README.md` (Key documents), `docs/designs/ci-pipeline.md`.
**Do:** add a top-level `concurrency` group that cancels in-progress runs on the same
ref; confirm via `gh api` that `main` has no required status checks; add one row to the
README's key-documents table and flip the design note's open question about required
checks to "deferred"; do a final full green run on a PR.
**Check:**
- V8 · `gh api` shows no required status checks on `main`
- V9 · `concurrency` is present and cancels superseded runs
- V1–V7 · the final PR run is green in both jobs
- `README.md` and the design note mention the pipeline

## Done

- [ ] `scripts/ci-checkpoint.sh all` green from a clean tree
- [ ] Every row of the design note's Verification table (V1–V9) is covered by a check
- [ ] Both jobs green on a PR before the workflow reaches `main`
- [ ] What changed from the design, and why
- [ ] What production needs that this omits (required checks, persistence, browser suite)

## Changes

One line each, newest first. Date — what changed in the plan or a check — why.
A check that now proves less starts with `LOOSENED:`.

- 2026-10-06 — CI02 check now expects lowercase `success` from `gh` (`SUCCESS` never matched) — the vocabulary was wrong, it proves the same.
- 2026-10-06 — plan written from `docs/designs/ci-pipeline.md` (Accepted), split into
  CI01–CI06 with the risky subnet step (CI02) before the portability migration (CI03).

## Step anatomy

| Part | Purpose |
|---|---|
| **Goal** | One line. What runs afterwards that did not before. |
| **Read** | Exact paths. Keeps a small context window for the work. |
| **Do** | Concrete actions, not outcomes. No code. |
| **Check** | Three to five plain-English assertions, tagged with the `Vn` row they cover. The script is written with the step. |
| **If it fails** | Only on the riskiest-assumption step (CI02). |

Each step also gets `docs/steps/CI<NN>.md` when it is worked: one sentence, a diagram
and a few plain bullets on what it changes. Nothing for it goes in the plan.

## Checkpoints

Written by the implementing agent with the step — before the step's code — at
`scripts/checks/CI<NN>.sh`, from the step's **Check** lines:

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"

describe "<the step's goal>" <<'EOF'
Proves: <what will be true if this passes>
How:    <what the script actually does to find out>
Needs:  <what must be running or built first>
EOF

require  "<precondition>"     "<where to look>"  <command>
check_eq "<what is proved>"   "<where to look>"  "<expected>" "$(<command>)"
check    "<what is proved>"   "<where to look>"  <command>

finish
```

Run with `scripts/ci-checkpoint.sh CI<NN>`. A passing run reads like the skill's
example: a `describe` block, one `[n] ok` line per check, and a `PASS: CI<NN> — n of n`
verdict; a failure says what it wanted, what it got, and where to look.

- **`scripts/ci-checkpoint.sh`, not `scripts/checkpoint.sh`.** The latter is the frozen
  Stage-H runner and is never overwritten. The CI plan's runner is separate and globs
  `scripts/checks/CI[0-9]*.sh`.
- Evidence goes to `docs/evidence/CI<NN>.log` (the repo's evidence dir, not the
  template's `evidence/`), because that is where `docs/evidence/` already lives and it
  keeps the CI logs out of the frozen `S*.log` set.
- **`e2e` checkpoints run live.** CI02, CI04 and CI05 prove their claims by dispatching
  the workflow (`gh workflow run` / `gh run watch`) and asserting the run is green. They
  need `gh` auth and take ~20–45 min each; they are the only honest way to check a
  GitHub-hosted run. All other checkpoints are local and fast.
- `scripts/ci-checkpoint.sh CI<NN> --explain` lists the checks without running them.
- `scripts/ci-checkpoint.sh all` runs every `CI*.sh` that exists, then a summary.
- `app/scripts/verify.sh` does **not** exit non-zero on a failed R-check (`:2`) — the
  checkpoints must call `make verify`, never the script directly.

## Sequencing advice

For writing the plan; none of it is a gate on running it.

1. **Baseline first** — CI01 runs the suites as they are, before any edit.
2. **Riskiest assumption early** — CI02, the subnet on a stock runner, with the exact
   fallback named.
3. **Novel logic against a stub** — CI02's `e2e` job is a probe; CI04 grows it into the
   cold path.
4. **Migration last** — CI03 is the only step that changes existing scripts, and its
   table lists every check it touches.

## Sizing

- A step should fit one session of a small-context model: about three files to read,
  about five checks, and a change one screen and one diagram can explain.
- But as few steps as give a runnable result each: `fast` and `e2e` are the two runnable
  halves; CI01–CI06 slice them so each has one thing to prove.
- A stage is two to five steps, ending where a human would want to look.
