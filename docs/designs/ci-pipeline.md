# CI Pipeline — Design Note (v1)

| Author | Date | Status | Ticket |
|--------|------|--------|--------|
| vjkancherla | 2026-10-05 | **Accepted** | none |

**Scope:** a report-only GitHub Actions pipeline that runs the repo's existing `make`
suites on push, PR and dispatch, plus the three portability edits that let the repo
build and run off the maintainer's arm64 Mac. It is **not** a production CI: no
required checks, no deploy, no secrets beyond `GITHUB_TOKEN`.

Supersedes: nothing. This is the first CI design note; it also amends nothing in the
root JIT design. It changes three existing scripts (`jit-runner/Dockerfile`,
`app/scripts/build.sh`, `app/scripts/verify.sh`) and adds one workflow file.

## Context read

- `README.md` — the repo is a k3d PoC; the suites are `make verify` (R1–R17) and
  `make jit-verify` (J1–J11); targets write `docs/evidence/<target>.log`; the console
  is a local page over `make state`. Two halves: `app/` and the JIT plane.
- `Makefile`, `app/Makefile` — the entry points. `make test-up` = cold path for both
  namespaces; `make console-test` = server + contract + browser-if-installed.
- `app/scripts/verify.sh` — `set -uo pipefail` with **no `-e`** (`:2`); it exits 0
  however many R-checks fail, which is why `Makefile:81` parses the summary line
  instead of trusting the exit code. Its R15 gate is arch-gated at `:333` and `:342`.
- `scripts/verify-jit.sh` — J2 requires the literal string
  `===== 17 PASS, 0 FAIL =====` (`:208`), so an unpassable R15 reds the whole J-suite.
- `docs/lessons.md:217` — the cold-path trap: `jit-controller:latest` lived in the
  Docker daemon and nowhere else; a cold host has nobody to import it.
- `scripts/jit-up.sh:37` — fails with a hint if `jit-controller:latest` is absent;
  nothing in `make test-up` builds it.
- `deploy/minio.sh:21` — aborts without `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`;
  `.gitignore:3` excludes `deploy/.env`; **no `.env.example` exists**.
- `deploy/runner.sh:19`, `deploy/minio.sh:25` — fixed `.10`/`.11`.
- `app/scripts/deploy.sh:45` — hardcoded `--subnet 172.19.0.0/16`.
- `scripts/checkpoint.sh:30` — the Stage-H gates refuse a dirty tree and write tracked
  `docs/evidence/*.log`, so they cannot share a push with a full e2e run.
- `git remote` — `github.com/vjkancherla/k8s-just-in-time-infra`; `gh` is installed and
  authenticated with the `workflow` scope, so dispatch-and-watch is available.
- Stated constraint: **"report-only: a red run never blocks a merge."** And: the
  maintainer's machine is the only host that has run any of this.

## Decision

One workflow file, `.github/workflows/ci.yml`, on `ubuntu-24.04`, with two
**independent parallel jobs** — `fast` (~2 min) and `e2e` (~20–45 min) — triggered on
push to `main`, on any pull request, and by `workflow_dispatch`. Report-only: no
required checks. Three portability edits land in the same change so the repo builds
and the R-suite can pass on amd64.

## Why the existing `make` suites are the checks (the load-bearing decision)

Everything else follows from this one: the CI does **not** reimplement verification.
It calls the same `make` targets a human runs, so there is exactly one definition of
"the app works" and "the JIT lifecycle works", and it is the one already proven on the
laptop. Concretely, the `e2e` job runs `make test-up`, `make console-test` and
`make jit-verify`, and the `fast` job runs the same pytest files and `lint-helpers.sh`
the repo already has.

- **Alternative — inline the commands in workflow YAML.** It loses local parity: a
  step that drifts from the Makefile runs one thing locally and another in CI, and the
  drift is invisible until it breaks. Rejected.
- **Alternative — rewrite the suites as a CI-native pytest harness.** It throws away
  the J1–J11 lifecycle suite (which no unit test reproduces) and is a much larger
  change than the pipeline itself. Rejected.
- This decision is why the portability edits are unavoidable and in scope: the suites
  were written against one arm64 laptop, so "run the suites on a stock runner" *is*
  "make the suites run on amd64."

Secondary decision (report-only): the pipeline never gates a merge. It exists to move
the detection of a regression from after `main` to before it, without requiring branch
protection. Alternative — required checks — is deferred, not rejected; it would need
the `e2e` job to be trusted first (see Open questions).

## Shape

```
        push / pull_request / workflow_dispatch
                        |
        +---------------+----------------+
        |                                |
   [ fast ]  ~2 min                 [ e2e ]  ~20-45 min
   ubuntu-24.04                     ubuntu-24.04
   venv + pytest + requests         pinned k3d install
   jit-controller/test_ipam.py      write deploy/.env
   jit-controller/test_declarers.py docker build jit-controller:latest
   console/test_serve.py            make test-up            (cold path, 2 ns)
   console/test_console.py          make console-test
   scripts/checks/lint-helpers.sh   make jit-verify         (J1-J11)
   python: already on image         upload-artifact on failure
   (no setup-python)                timeout-minutes: 45
                        |                                |
                        +---------------+----------------+
                                        |
                              report-only: nothing blocks a merge
```

Both jobs run on `ubuntu-24.04` (pinned) so the base image cannot move under the
hardcoded subnet, fixed container IPs and host ports.

## Core mechanism — the cold path, in order

The `e2e` job reproduces `docs/evidence/s17-cold-path-green.log` on a stock runner.
Order is load-bearing:

1. `deploy/.env` must exist **before** any MinIO step (`deploy/minio.sh:21`), so the job
   writes it with fixed throwaway CI credentials — the real file is gitignored and
   absent from a fresh checkout, and there is no `.env.example` to copy.
2. `jit-controller:latest` must be **built** before `make test-up` (`scripts/jit-up.sh:37`
   fails otherwise, and nothing in `make test-up` builds it — the cold-path lesson).
3. `make test-up` runs the cold path for both namespaces; `make verify` inside it must
   reach `17 PASS, 0 FAIL`.
4. `make jit-verify` runs J1–J11, whose J2 re-checks that R summary.

On the second identical run of the workflow, everything is rebuilt from scratch: GitHub
runners keep no state between runs, so there is nothing to be idempotent about.

## Failure modes handled

1. **The suite's exit code lies.** `app/scripts/verify.sh` exits 0 with failing checks
   (`:2`), so CI must not trust it — the workflow calls `make verify`, which re-parses
   the summary (`Makefile:81`) and exits non-zero on any FAIL. Handled by calling the
   Makefile, not the script.
2. **Cold host has no controller image.** The job builds `jit-controller:latest` before
   `make test-up`. Handled explicitly (this is the `lessons.md:217` trap).
3. **A fresh checkout has no `deploy/.env`.** The job writes it before the first MinIO
   step. Handled.
4. **The subnet may collide on a stock runner.** `172.19.0.0/16` plus fixed `.10`/`.11`
   are untested off-Mac. *Not handled* — this is the first-run experiment; the Rollout
   names the single-line fix and where it lands.

Not handled, deliberately: state does not survive a runner restart (MinIO `jit-state`,
the `jit-ipam` ConfigMap and orphaned volumes are never exercised across a reboot);
`console/test_browser.py` is excluded (a Playwright venv plus a ~60 s chromium download
to test a page against fixtures it writes itself); there are no required checks.

## Verification

Written before the build plan; every row is a check that would convince a sceptic.
Numbered `Vn` so the plan's `Check:` lines ladder up to it.

| # | Check |
|---|---|
| V1 | The `fast` job is green on a stock `ubuntu-24.04` runner: `test_ipam.py`, `test_declarers.py`, `test_serve.py`, `test_console.py` all pass, and `scripts/checks/lint-helpers.sh` prints PASS. |
| V2 | The `e2e` job creates the k3d cluster on `--subnet 172.19.0.0/16` and starts a container at `172.19.0.10` that is reachable — no collision on a stock runner. |
| V3 | The app images and `jit-controller:latest` build natively on amd64 with no `--platform linux/arm64` and the tofu download resolves to `linux_amd64`. |
| V4 | The `e2e` job completes `make test-up` (both namespaces, cold path) and `make verify` reaches `===== 17 PASS, 0 FAIL =====`. |
| V5 | The `e2e` job completes `make jit-verify` (J1–J11), proving the R15 change makes the J2 literal reachable on amd64. |
| V6 | `make console-test` passes (server + contract; browser suite skipped). |
| V7 | On any failure, the job uploads `docs/evidence/` and `app/.workflow/` as an artifact. |
| V8 | The pipeline is report-only: no required status checks on `main`, so a red run does not block a merge. |
| V9 | The file parses and declares exactly two jobs and the three triggers; `pull_request` triggers the run before the workflow is on `main`. |

**The three that matter:** V2 (the only genuinely unknown thing — the subnet on a stock
runner), V4 (the cold path, the whole point), and V5 (the J-suite, which is the check
most likely to be quietly unreachable). V1 is the baseline; V3 restores portability.

## Roads not taken

- **`ubuntu-latest`** — rejected: it moves to Ubuntu 26.04 in November 2026, under a
  repo that hardcodes a Docker subnet, fixed container IPs and host ports. Pin the
  version; revisit deliberately.
- **`macos-14`, zero edits** — rejected: that runner image ships no container runtime
  and no `kubectl`, so Docker would need a nested VM.
- **Two workflow files** — rejected: the jobs do not serialize, so a second file buys
  nothing.
- **Running the `S*.sh` checkpoint gates** — rejected: `scripts/checkpoint.sh:30`
  refuses a dirty tree and every gate writes a tracked `docs/evidence/*.log`, so it
  cannot share a push with the `e2e` job; `S29` alone is 25–35 min.
- **`actions/setup-python`** — rejected: the runtime is already on the image.
- **A third-party k3d action** — rejected: a supply-chain dependency for three lines
  that `curl` does, and the repo pins no k3d version anywhere.
- **Branch protection / required checks** — deferred, not rejected; report-only was the
  explicit choice (see Open questions).

## Open questions

- [ ] Does `172.19.0.0/16` collide on a stock `ubuntu-24.04` runner? **Blocking until
  the first `e2e` run (V2).** If it does, change the one `--subnet` argument and the
  fixed `.10`/`.11` call sites — not the 29 hardcoded `172.19.0.x` sites. (vjkancherla)
- [ ] Should R15's dropped architecture check become its own assertion, or stay
  report-only? Deferred until the pipeline is trusted. (vjkancherla)
- [ ] Should `fast` and `e2e` become required checks once the `e2e` job is trusted?
  **Deferred (CI06):** the pipeline stays report-only — a red run never blocks a
  merge — until the `e2e` job has been green long enough to trust. (vjkancherla)
- [ ] State never survives a runner restart, so MinIO `jit-state`, `jit-ipam` and
  orphaned volumes are never exercised across a reboot. Needs a service container or a
  persistent volume — a larger change than the pipeline. (unassigned)
- [ ] `console/test_browser.py` is excluded. Add when a console UI regression costs
  something. (vjkancherla)

## Effort

**1–2 days.** The three portability edits are an hour and are behaviour-preserving on
the Mac. The workflow skeleton and the `fast` job are an hour. The error-prone part is
the `e2e` cold path on a stock runner — the state that a warm laptop hides — and it
should be done **early**, before the polish: it is the one place the design can turn out
to be wrong. Expect 2–4 dispatch-and-watch cycles at ~20–45 min each while the cold path
settles, which is why V2 is its own step.
