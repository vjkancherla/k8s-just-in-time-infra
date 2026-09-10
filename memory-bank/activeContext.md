Updated: 2026-09-10

## Current focus
S17 is DONE and committed (`a82a6a9..e00a179`). Its checkpoint has passed on a complete run; the
review has not been run, so `docs/todo.md`'s S17 `review` box is unticked on purpose.

## Done (verified)
- `bash scripts/checks/S17.sh` → exit 0: `make jit-verify` = J1-J11 **11 PASS, 0 FAIL**, then
  `make verify` in voting-a = **17 PASS, 0 FAIL**, ending `PASS: S17 - two namespaces, J1-J11 and
  the R-checks both green`. Run: `/tmp/s17-run.log`; report `/tmp/verify-jit-green.md`.
- J1's duplicate IP is fixed and shown repeatable, not lucky: `/tmp/race-test.sh` = **3/3 OK**,
  three distinct IPs and IPAM `count: 3` on every iteration. Two causes - allocation was locked
  per claim instead of per namespace, and `release_block` fired twice per swept claim.
- J11 needed two repairs to become assertable at all: its SigV4 prefix must be `ns%2F` (signed as
  `ns/` it got 403 from MinIO), and it had no `pass` line, so a passing J11 printed nothing.
- J10's reworked assertion (a claim waiting on a dependency has *no* phase, not `Pending`) passes
  in a complete run.
- Also fixed here: pgadmin's servers.json visible to the Docker daemon, `jit-pgadmin` port 80,
  pgadmin's destroy without `postgres_url`, the runner's destroy never resolving to an unnamed
  module, R14/R15 namespace scoping, `deploy/minio.sh` 409. S16 committed at 5dd3352; its gate
  needs `NS=voting-a`.

## Checkpoints (final code)
- PASS: S17, `bash scripts/checks/S17.sh` (third full run; runs 1-2 failed at J11 and are kept -
  they are what found the two defects)
- PASS: S0-S16, committed.

## Commits
S17: 36a86b2 (controller), cfb99c0 (pgadmin), d65f62d (runner), 99a1397 (JIT suite + Makefile),
15991b5 (app sources + S01-S07 gates), 8a67327 (two namespaces + scoped R-checks), e00a179 (docs).

## Next step
Run the S17 review in a *fresh* task: `Read and follow docs/reviews/S17-review-prompt.md`. Tick
`review` in `docs/todo.md` only when `docs/reviews/S17-findings.md` says CLEAR.

## Watch out
- `docs/reviews/REVIEW-PROMPT-TEMPLATE.md` does not exist; the S17 prompt follows the S13-S16 shape.
- `scripts/checks/S00.sh` fails by design (pre-migration assertions). Decided in S17, not a
  regression - do not "fix" it.
- The controller assumes a single replica, which is what `namespace_lock` and `claim_lock` rely on.