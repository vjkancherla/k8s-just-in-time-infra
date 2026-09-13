Updated: 2026-09-13

## Working
`claim` is in and verified; S18's gate is red by design until the frozen-file amendment is approved.

## Done (verified)
- `make claim NS=.. MODULE=..` sits beside `state` in the Makefile and in `CONSOLE_TARGETS`: one InfraClaim as
  YAML with stderr left alone, so `serve.py`'s GET /claim shows kubectl's error verbatim. Verified live.
- `docs/evidence/claim-allowlist.log`: the frozen file's 12-vs-13 FAIL (rc=1), then a one-line copy's twelve ok
  lines and `PASS` (rc=0), plus that run's own `state.log` reads, which prove they were not vacuous.
- Independent review (`docs/reviews/S18-findings.md`, `16fa4ad`): no blockers; four concerns, listed there.
- Every target that runs appends `docs/evidence/<target>.log` and keeps its exit code; `make verify` exits on the
  summary it wrote (0 at 17 PASS, 2 at 11 FAIL).

## Broken (confirmed by execution)
- `make demo-up` (02:19 cold) exited 2: R-checks `12 PASS, 5 FAIL`, all five the Ingress-facing ones reporting curl
  `code=000`, while R13/R16 — same curl, same URL — passed seconds later in the same run. Cause not established.
- `make state` emits no `ingresses`/`ingressPorts` while `console/index.html:670` reads both, so the Voting-app
  panes have no URLs to build (`console/README.md` names them as what the app panes point at).

## Suspected (read, not reproduced)
- Postgres's password can disagree across its data directory, the container's `POSTGRES_PASSWORD` and the
  `jit-postgres` Secret after a re-provisioning, leaving pods rejected — seen once, on a warm bring-up.
- `app/scripts/verify.sh` still returns 0 however many R-checks fail, by design.
- `ipam.py` has no lock of its own; `_allocated_ip` cannot tell a failed read from "no address".

## In progress
Nothing.

## Blocked
- Nothing blocked. Only the S18 amendment waits, and it needs your approval rather than more work.

## Learnings
- A checkpoint whose last assertions read the cluster can pass vacuously: a `make destroy` landing mid-run made two
  of S18's ok lines true against zero claims. Read the run's own `state.log` reads before believing a PASS.
- Link and anchor checks belong in a script: a README's `](#anchor)` targets and relative paths all validate in
  one pass, and a checker that forgets to skip code fences reports phantom failures.
- A frozen gate that cannot pass is a design question, not a checkpoint edit: prove it on a patched copy, leave
  the frozen file byte-identical until the human rules, and the copy's PASS is the question's evidence.
- `python3 - <<'PY' <<<"$data"`: the herestring wins on fd 0 — pass data as argv; `make -pRrq :` needs `|| true` first.
